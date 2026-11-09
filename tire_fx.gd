extends Node3D
## Tire smoke and skid marks. Must be a direct child of the car (VehicleBody3D using car.gd).

@export var wheel_paths: Array[NodePath] = [^"../BL", ^"../BR"]
@export var min_intensity := 0.15
@export var full_smoke_angle_deg := 30.0  ## slip angle at which smoke and marks are at full strength

@export_group("Smoke")
## Grey, see-through, wispy smoke: dense continuous trail that spreads out and frays away
@export var smoke_amount := 320
@export var smoke_lifetime := 3.0
@export var smoke_color := Color(0.72, 0.72, 0.74, 0.4)
@export var smoke_size := 1.1
@export var smoke_growth := 3.0          ## size multiplier reached at the end of a puff's life
@export var smoke_rise := 0.35

@export_group("Skid marks")
@export var skid_width := 0.22
@export var skid_color := Color(0.04, 0.04, 0.05, 0.7)
@export var skid_max_segments := 4000     ## oldest marks get overwritten past this
@export var skid_segment_length := 0.2

@onready var car: VehicleBody3D = get_parent()

var wheels: Array[VehicleWheel3D] = []
var smokes: Array[GPUParticles3D] = []
var last_points: Array = []               # Vector3, or null when the wheel isn't marking
var marks: MultiMesh
var next_mark := 0


func _ready() -> void:
	for path in wheel_paths:
		wheels.append(get_node(path))
		smokes.append(_create_smoke())
		last_points.append(null)
	_create_skid_marks()


func _physics_process(_delta: float) -> void:
	for i in wheels.size():
		var wheel := wheels[i]
		var intensity := _slide_intensity(wheel)
		var active := wheel.is_in_contact() and intensity > min_intensity

		var smoke := smokes[i]
		smoke.emitting = active
		if not active:
			last_points[i] = null
			continue

		var point := wheel.get_contact_point()
		var normal := wheel.get_contact_normal()
		smoke.global_position = point + normal * 0.15
		smoke.amount_ratio = intensity

		var last = last_points[i]
		if last == null or point.distance_to(last) > 3.0:  # > 3 m means a teleport (reset), don't draw
			last_points[i] = point
		elif point.distance_to(last) >= skid_segment_length:
			_add_mark(last, point, normal)
			last_points[i] = point


func _slide_intensity(wheel: VehicleWheel3D) -> float:
	var intensity := 0.0
	if car.is_drifting:
		intensity = clampf(absf(car.slip_angle) / deg_to_rad(full_smoke_angle_deg), 0.0, 1.0)
		if Input.is_action_pressed("handbrake") and car.speed > 3.0:
			intensity = maxf(intensity, 0.6)
	# get_skidinfo() is 1 with full grip and drops toward 0 when the wheel spins (burnouts).
	# Only trusted on throttle: a wheel at rest also reports a low value.
	if car.throttle_input > 0.3:
		intensity = maxf(intensity, 1.0 - wheel.get_skidinfo())
	return intensity


func _add_mark(from: Vector3, to: Vector3, normal: Vector3) -> void:
	var dir := to - from
	var length := dir.length()
	var forward := (dir - normal * dir.dot(normal)).normalized()
	var right := normal.cross(forward)
	var basis := Basis(right * skid_width, normal, forward * length)
	var origin := (from + to) * 0.5 + normal * 0.02  # lift a bit to avoid z-fighting with the ground
	marks.set_instance_transform(next_mark, Transform3D(basis, origin))
	next_mark = (next_mark + 1) % skid_max_segments
	marks.visible_instance_count = mini(marks.visible_instance_count + 1, skid_max_segments)


func _create_smoke() -> GPUParticles3D:
	# Soft billboard whose edge is broken up by noise. As the puff ages, more of it falls under the noise
	# threshold, so it frays into wisps instead of just fading. Lit, so it takes the color of the sunset.
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode depth_draw_never, cull_disabled, shadows_disabled, diffuse_lambert_wrap, specular_disabled;
uniform sampler2D noise_tex : repeat_enable, filter_linear;
varying float life;
varying vec2 noise_offset;

void vertex() {
	// face the camera, spin by the particle angle, keep the particle scale
	float a = INSTANCE_CUSTOM.x;
	mat4 world = mat4(normalize(INV_VIEW_MATRIX[0]), normalize(INV_VIEW_MATRIX[1]), normalize(INV_VIEW_MATRIX[2]), MODEL_MATRIX[3]);
	world = world * mat4(vec4(cos(a), -sin(a), 0.0, 0.0), vec4(sin(a), cos(a), 0.0, 0.0), vec4(0.0, 0.0, 1.0, 0.0), vec4(0.0, 0.0, 0.0, 1.0));
	world = world * mat4(vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0), vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
		vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0), vec4(0.0, 0.0, 0.0, 1.0));
	MODELVIEW_MATRIX = VIEW_MATRIX * world;
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
	life = INSTANCE_CUSTOM.y;
	noise_offset = vec2(fract(a * 7.31), fract(a * 3.17));   // each puff samples its own part of the noise
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float falloff = 1.0 - smoothstep(0.15, 1.0, length(p));
	float n = texture(noise_tex, UV * 0.7 + noise_offset + vec2(life * 0.15, -life * 0.1)).r;
	float density = falloff * (0.45 + n);
	// threshold rises with age: the puff thins out and breaks into wisps
	float cut = mix(0.15, 0.85, life);
	ALBEDO = COLOR.rgb;
	ALPHA = COLOR.a * smoothstep(cut, cut + 0.35, density);
}
"""
	var noise := FastNoiseLite.new()
	noise.frequency = 0.02
	noise.fractal_octaves = 4
	var noise_tex := NoiseTexture2D.new()
	noise_tex.width = 128
	noise_tex.height = 128
	noise_tex.seamless = true
	noise_tex.noise = noise
	var draw_mat := ShaderMaterial.new()
	draw_mat.shader = shader
	draw_mat.set_shader_parameter("noise_tex", noise_tex)

	var quad := QuadMesh.new()
	quad.size = Vector2.ONE * smoke_size
	quad.material = draw_mat

	var fade := Gradient.new()
	fade.offsets = PackedFloat32Array([0.0, 0.06, 0.5, 1.0])
	fade.colors = PackedColorArray([Color(1, 1, 1, 0), Color(1, 1, 1, 1), Color(1, 1, 1, 0.65), Color(1, 1, 1, 0)])
	var fade_tex := GradientTexture1D.new()
	fade_tex.gradient = fade

	var grow := Curve.new()
	grow.max_value = smoke_growth
	grow.add_point(Vector2(0, 0.5))
	grow.add_point(Vector2(0.35, smoke_growth * 0.65))
	grow.add_point(Vector2(1, smoke_growth))
	var grow_tex := CurveTexture.new()
	grow_tex.curve = grow

	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process.emission_sphere_radius = 0.2
	process.direction = Vector3.UP
	process.spread = 60.0
	process.initial_velocity_min = 0.5
	process.initial_velocity_max = 1.5
	process.gravity = Vector3(0, smoke_rise, 0)
	# puffs slow down quickly and hang behind the car, then drift and spread
	process.damping_min = 1.5
	process.damping_max = 2.5
	process.inherit_velocity_ratio = 0.2
	process.scale_min = 0.8
	process.scale_max = 1.2
	process.scale_curve = grow_tex
	process.color = smoke_color
	process.color_ramp = fade_tex
	process.angle_min = -180.0
	process.angle_max = 180.0
	process.angular_velocity_min = -25.0
	process.angular_velocity_max = 25.0

	var smoke := GPUParticles3D.new()
	smoke.top_level = true
	smoke.amount = smoke_amount
	smoke.lifetime = smoke_lifetime
	smoke.local_coords = false
	smoke.emitting = false
	smoke.interpolate = true   # spread the puffs along the path between frames: a continuous trail, not dots
	smoke.process_material = process
	smoke.draw_pass_1 = quad
	smoke.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	smoke.draw_order = GPUParticles3D.DRAW_ORDER_VIEW_DEPTH
	# Particles stay in world space while the emitter moves, so the box must cover the whole trail
	smoke.visibility_aabb = AABB(Vector3(-100, -5, -100), Vector3(200, 25, 200))
	add_child(smoke)
	return smoke


func _create_skid_marks() -> void:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = skid_color
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.disable_fog = true

	var plane := PlaneMesh.new()
	plane.size = Vector2.ONE
	plane.material = mat

	marks = MultiMesh.new()
	marks.transform_format = MultiMesh.TRANSFORM_3D
	marks.mesh = plane
	marks.instance_count = skid_max_segments
	marks.visible_instance_count = 0

	var instance := MultiMeshInstance3D.new()
	instance.top_level = true
	instance.multimesh = marks
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	instance.custom_aabb = AABB(Vector3(-5000, -500, -5000), Vector3(10000, 1000, 10000))
	add_child(instance)
	instance.global_transform = Transform3D.IDENTITY
