extends Node3D
## Dark purple light trails left behind the rear wheels while boosting. Each point of a trail fades out and
## thins down over trail_time, so the trail shrinks away once the boost stops. Added by car.gd.

@export var trail_time := 0.4      ## seconds a trail point stays visible
@export var width := 0.05
@export var color := Color(0.32, 0.05, 0.62)
@export var energy := 2.2          ## above 1 the trail glows (the maps have glow on)

@onready var car: Node3D = get_parent()   # car.gd (VehicleBody3D), read untyped for is_boosting

var _wheels: Array[VehicleWheel3D] = []
var _trails: Array = []            # per wheel: Array of [position, side direction, time]
var _mesh := ImmediateMesh.new()
var _time := 0.0


func _ready() -> void:
	_wheels = [car.get_node("BL"), car.get_node("BR")]
	for w in _wheels:
		_trails.append([])

	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;
uniform vec3 color : source_color = vec3(0.32, 0.05, 0.62);
uniform float energy = 2.2;
void fragment() {
	// COLOR.r: 1 in the middle of the strip, 0 on its edges (a brighter core); COLOR.a: fade with age
	ALBEDO = mix(color, vec3(0.62, 0.35, 0.95), COLOR.r * 0.4) * energy;
	ALPHA = COLOR.a * mix(0.35, 1.0, COLOR.r);
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("color", color)
	mat.set_shader_parameter("energy", energy)

	var instance := MeshInstance3D.new()
	instance.top_level = true
	instance.mesh = _mesh
	instance.material_override = mat
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	instance.custom_aabb = AABB(Vector3(-5000, -500, -5000), Vector3(10000, 1000, 10000))
	add_child(instance)
	instance.global_transform = Transform3D.IDENTITY


func _process(delta: float) -> void:
	_time += delta
	# positions as drawn this frame (physics interpolation), so the trail stays glued to the wheels
	var body := (car as Node3D).get_global_transform_interpolated().basis
	var up := body.y
	for i in _wheels.size():
		var trail: Array = _trails[i]
		if car.get("is_boosting"):
			var w := _wheels[i]
			var p: Vector3 = w.get_global_transform_interpolated().origin - up * w.wheel_radius
			p += up * 0.06
			if not trail.is_empty() and trail[-1][0].distance_to(p) > 4.0:
				trail.clear()   # teleport (reset): don't draw a line across the map
			if trail.is_empty() or trail[-1][0].distance_to(p) > 0.12:
				trail.append([p, body.x, _time])
		while not trail.is_empty() and _time - trail[0][2] > trail_time:
			trail.pop_front()
	_rebuild()


func _rebuild() -> void:
	_mesh.clear_surfaces()
	var drawable := false
	for trail in _trails:
		if trail.size() >= 2:
			drawable = true
	if not drawable:
		return
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for trail in _trails:
		for k in trail.size() - 1:
			var a: Array = trail[k]
			var b: Array = trail[k + 1]
			var fa := clampf(1.0 - (_time - a[2]) / trail_time, 0.0, 1.0)
			var fb := clampf(1.0 - (_time - b[2]) / trail_time, 0.0, 1.0)
			# each segment is two halves (edge -> middle -> edge) so the middle can be brighter
			for side in [-1.0, 1.0]:
				var a_edge: Vector3 = a[0] + a[1] * side * width * 0.5 * fa
				var b_edge: Vector3 = b[0] + b[1] * side * width * 0.5 * fb
				_vertex(a[0], 1.0, fa)
				_vertex(a_edge, 0.0, fa)
				_vertex(b[0], 1.0, fb)
				_vertex(a_edge, 0.0, fa)
				_vertex(b_edge, 0.0, fb)
				_vertex(b[0], 1.0, fb)
	_mesh.surface_end()


func _vertex(p: Vector3, core: float, alpha: float) -> void:
	_mesh.surface_set_color(Color(core, 0.0, 0.0, alpha))
	_mesh.surface_add_vertex(p)
