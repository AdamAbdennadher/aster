extends Node3D
## Tire smoke and skid marks. Must be a direct child of the car (VehicleBody3D using car.gd).

@export var wheel_paths: Array[NodePath] = [^"../BL", ^"../BR"]
@export var min_intensity := 0.15
@export var full_smoke_angle_deg := 30.0  ## slip angle at which smoke and marks are at full strength

@export_group("Smoke")
@export var smoke_amount := 220
@export var smoke_lifetime := 4.5
@export var smoke_color := Color(1.0, 0.85, 0.85, 0.3)
@export var smoke_size := 2.0
@export var smoke_growth := 4.5          ## size multiplier reached at the end of a puff's life
@export var smoke_rise := 0.15

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
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, 0.5, 1.0])
	gradient.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0.6), Color(1, 1, 1, 0)])
	var puff := GradientTexture2D.new()
	puff.gradient = gradient
	puff.fill = GradientTexture2D.FILL_RADIAL
	puff.fill_from = Vector2(0.5, 0.5)
	puff.fill_to = Vector2(1.0, 0.5)

	var draw_mat := StandardMaterial3D.new()
	draw_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	draw_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	draw_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	draw_mat.billboard_keep_scale = true
	draw_mat.vertex_color_use_as_albedo = true
	draw_mat.albedo_texture = puff

	var quad := QuadMesh.new()
	quad.size = Vector2.ONE * smoke_size
	quad.material = draw_mat

	var fade := Gradient.new()
	fade.offsets = PackedFloat32Array([0.0, 0.08, 0.6, 1.0])
	fade.colors = PackedColorArray([Color(1, 1, 1, 0), Color(1, 1, 1, 1), Color(1, 1, 1, 0.7), Color(1, 1, 1, 0)])
	var fade_tex := GradientTexture1D.new()
	fade_tex.gradient = fade

	var grow := Curve.new()
	grow.max_value = smoke_growth
	grow.add_point(Vector2(0, 0.5))
	grow.add_point(Vector2(0.3, smoke_growth * 0.6))
	grow.add_point(Vector2(1, smoke_growth))
	var grow_tex := CurveTexture.new()
	grow_tex.curve = grow

	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process.emission_sphere_radius = 0.25
	process.direction = Vector3.UP
	process.spread = 90.0
	process.initial_velocity_min = 0.5
	process.initial_velocity_max = 2.0
	process.gravity = Vector3(0, smoke_rise, 0)
	# High damping makes puffs stop quickly and hang in the air, so they pile up behind the car
	process.damping_min = 2.0
	process.damping_max = 3.0
	process.inherit_velocity_ratio = 0.15
	process.scale_curve = grow_tex
	process.color = smoke_color
	process.color_ramp = fade_tex
	process.angle_min = -180.0
	process.angle_max = 180.0

	var smoke := GPUParticles3D.new()
	smoke.top_level = true
	smoke.amount = smoke_amount
	smoke.lifetime = smoke_lifetime
	smoke.local_coords = false
	smoke.emitting = false
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
