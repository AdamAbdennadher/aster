@tool
extends Node3D
## Procedural track: terrain, road with markings, guardrails on tight corners, props (trees, cacti, rocks),
## optional sea and snowfall. Everything is rebuilt on load (and in the editor), nothing generated is saved.

enum Biome { MOUNTAIN, DESERT, SNOW, JUNGLE, ISLAND }
enum Surface { ASPHALT, DIRT, SAND }

@export var regenerate := false:
	set(value):
		if value and is_inside_tree():
			_watch_path()
			generate()

@export var biome := Biome.MOUNTAIN
@export var surface := Surface.ASPHALT
@export var map_seed := 7

@export_group("Road")
## Closed loop, each point is (x, z, height). Only used when there is no "RoadPath" child (Path3D):
## with one, the road follows the points of its curve, which can be dragged in the 3D view.
@export var road_points := PackedVector3Array([
	Vector3(0, 150, 0), Vector3(0, 20, 2), Vector3(30, -80, 6), Vector3(120, -130, 10),
	Vector3(210, -90, 15), Vector3(240, 0, 20), Vector3(300, 60, 26), Vector3(360, 0, 32),
	Vector3(320, -90, 38), Vector3(330, -200, 44), Vector3(250, -300, 48), Vector3(120, -330, 46),
	Vector3(0, -280, 42), Vector3(-80, -330, 38), Vector3(-180, -280, 32), Vector3(-200, -180, 26),
	Vector3(-290, -150, 22), Vector3(-330, -40, 18), Vector3(-260, 60, 12), Vector3(-300, 160, 8),
	Vector3(-200, 260, 5), Vector3(-90, 250, 2),
])
@export var road_height_scale := 1.6      ## multiplies the heights in road_points
@export var road_width := 9.0
@export var verge_width := 1.2            ## gravel/snow strip on each side of the road
@export var guardrail_curvature := 0.014  ## 1/m, corners tighter than ~70 m radius get a rail on the outside
@export var spawn_sample := 5             ## where the car starts along the road (1 sample = 2 m)
@export var spawn_height := 0.68           ## car body height above the road at spawn (it rests at about 0.65, so it barely drops)
@export var finish_offset := 15            ## the finish line is this many samples ahead of the spawn (1 sample = 2 m)
## Road surface by stretch: each entry is (from road point, to road point, type) with type 1 = dirt, 2 = sand.
## Everything else is the map surface. Bridges get wooden planks automatically.
@export var surface_sections := PackedVector3Array()

@export_group("Terrain")
@export var map_size := 1400.0
@export var terrain_step := 5.0
@export var hill_height := 24.0
@export var mountain_height := 180.0
@export var terrace_step := 0.0           ## > 0 cuts the mountains into flat layers (desert mesas)
@export var prop_density := 1.0

@export_group("Sea")
@export var sea_enabled := false
@export var sea_level := -4.0
@export var coast_direction := Vector2(0, 1)  ## points from land toward the sea (x, z)
@export var coast_offset := 260.0             ## distance from the road center to the shoreline along coast_direction
@export var water_shallow_color := Color(0.2, 0.95, 0.85)
@export var water_deep_color := Color(0.0, 0.48, 0.72)
@export var water_depth_range := 7.0          ## meters over which the water goes from shallow to deep color
@export var beach_height := 3.0                ## height of the sand band above the water
@export var lagoon_depth := 1.5                ## depth of the shallow band along the coast, before the open sea
@export var sea_foam_width := 0.9
@export var water_reflection := 1.0             ## how much the sea mirrors the sky (lower keeps it turquoise far away)
## > 0: the sea surrounds an island of this radius (with an uneven coastline) instead of lying on one side
@export var island_radius := 0.0
@export var island_center := Vector2.ZERO

@export_group("Volcano")
@export var volcano_height := 0.0             ## 0 = none. Cone at island_center with a glowing crater
@export var volcano_radius := 170.0

@export_group("Ponds")
@export var ponds_enabled := false
@export var pond_count := 14
@export var pond_radius := Vector2(12, 28)   ## min / max radius in meters
@export var pond_depth := 3.0
## A big lake at a fixed spot (0 = none). Roads crossing it become bridges.
@export var lake_radius := 0.0
@export var lake_center := Vector2.ZERO
@export var lake_level := 1.0
@export var lake_depth := 6.0

@export_group("Weather")
@export var snowfall := false

const SAMPLE_SPACING := 2.0
const LOOKUP_CELL := 18.0

var samples: PackedVector3Array = []
var tangents: PackedVector3Array = []
var distances: PackedFloat32Array = []

var _cells := {}
var _coarse: PackedInt32Array = []
var _heights: PackedFloat32Array = []
var _grid_n := 0
var _origin := Vector2.ZERO
var _road_center := Vector2.ZERO
var _nearest_dist := 0.0
var _nearest_index := 0
var _generated: Node3D
var _snow: GPUParticles3D
var _regen_at := -1.0
var _ponds: Array = []        # {c: Vector2 center, r: radius, level: water height}
var _bridge := PackedByteArray()  # per road sample: 1 where the road runs over water (bridge deck, with a few samples of margin)
var _lake_noise: FastNoiseLite
var _island_noise: FastNoiseLite


func _ready() -> void:
	if Engine.is_editor_hint():
		_watch_path()
	generate()
	if not Engine.is_editor_hint():
		_place_car()
		var race: Node = load("res://scripts/race.gd").new()
		race.name = "Race"
		race.setup(self, finish_index())
		add_child(race)


# Editor only: rebuild the map shortly after the RoadPath curve stops changing (rebuilding takes ~1.5 s,
# doing it on every mouse move while dragging a point would freeze the editor)
func _process(_delta: float) -> void:
	if _regen_at > 0.0 and Time.get_ticks_msec() / 1000.0 >= _regen_at:
		_regen_at = -1.0
		generate()


func _watch_path() -> void:
	var path := get_node_or_null("RoadPath") as Path3D
	if path and path.curve and not path.curve.changed.is_connected(_on_path_changed):
		path.curve.changed.connect(_on_path_changed)


func _on_path_changed() -> void:
	_regen_at = Time.get_ticks_msec() / 1000.0 + 0.5


func _physics_process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if sea_enabled:
		var car := get_node_or_null("Car/Car")
		if car and car.global_position.y < sea_level - 1.5:
			car.reset_car()
	if not _ponds.is_empty():
		var car := get_node_or_null("Car/Car")
		if car:
			var p := Vector2(car.global_position.x, car.global_position.z)
			for pond in _ponds:
				if p.distance_to(pond.c) < pond.r and car.global_position.y < pond.level - 1.2:
					car.reset_car()
	if _snow:
		var cam := get_viewport().get_camera_3d()
		if cam:
			_snow.global_position = cam.global_position + Vector3.UP * 12.0


func generate() -> void:
	if _generated:
		_generated.free()
	_snow = null
	_generated = Node3D.new()
	_generated.name = "Generated"
	add_child(_generated)

	_build_road_path()
	_build_lookup()
	_build_terrain()
	_build_road_mesh()
	_build_guardrails()
	_build_bridges()
	_build_finish_line()
	_build_props()
	if sea_enabled:
		_build_sea()
	if volcano_height > 0.0:
		_build_crater_glow()
	if not _ponds.is_empty():
		_build_ponds_water()
	if snowfall:
		_build_snowfall()


# ---------- Biome presets ----------

func _palette() -> Dictionary:
	match biome:
		Biome.DESERT:
			return {
				"ground": Color(0.72, 0.5, 0.31), "ground_alt": Color(0.62, 0.41, 0.25),
				"steep": Color(0.52, 0.27, 0.17), "verge": Color(0.58, 0.42, 0.28),
				"beach": Color(0.86, 0.72, 0.5), "road_verge": Color(0.6, 0.45, 0.3),
				"asphalt": Color(0.13, 0.11, 0.11),
			}
		Biome.ISLAND:
			return {
				"ground": Color(0.13, 0.3, 0.09), "ground_alt": Color(0.2, 0.36, 0.11),
				"steep": Color(0.3, 0.25, 0.2), "verge": Color(0.9, 0.75, 0.42),
				"beach": Color(0.99, 0.86, 0.5), "road_verge": Color(0.86, 0.7, 0.4),
				"asphalt": Color(0.13, 0.13, 0.15), "volcanic": Color(0.2, 0.16, 0.15),
			}
		Biome.JUNGLE:
			return {
				"ground": Color(0.05, 0.12, 0.04), "ground_alt": Color(0.1, 0.17, 0.05),
				"steep": Color(0.17, 0.13, 0.09), "verge": Color(0.33, 0.16, 0.09),
				"beach": Color(0.38, 0.3, 0.19), "road_verge": Color(0.24, 0.17, 0.1),
				"asphalt": Color(0.11, 0.11, 0.12),
			}
		Biome.SNOW:
			return {
				"ground": Color(0.86, 0.89, 0.95), "ground_alt": Color(0.77, 0.81, 0.9),
				"steep": Color(0.3, 0.3, 0.34), "verge": Color(0.62, 0.62, 0.66),
				"beach": Color(0.86, 0.89, 0.95), "road_verge": Color(0.7, 0.7, 0.74),
				"asphalt": Color(0.1, 0.1, 0.12),
			}
		_:
			return {
				"ground": Color(0.12, 0.16, 0.07), "ground_alt": Color(0.24, 0.22, 0.1),
				"steep": Color(0.24, 0.21, 0.2), "verge": Color(0.26, 0.2, 0.14),
				"beach": Color(0.5, 0.45, 0.3), "road_verge": Color(0.22, 0.19, 0.15),
				"asphalt": Color(0.12, 0.11, 0.13),
			}


# Each prop: mesh, count, min distance to road, collision radius (0 = none), scale range, sink into ground
func _props() -> Array:
	match biome:
		Biome.DESERT:
			return [
				{"mesh": _cactus_mesh(), "count": 900, "road_gap": 5.0, "radius": 0.4, "scale": Vector2(0.7, 1.4), "sink": 0.2},
				{"mesh": _rock_mesh(Color(0.5, 0.28, 0.18)), "count": 700, "road_gap": 4.0, "radius": 1.0, "scale": Vector2(0.4, 2.5), "sink": 0.4},
			]
		Biome.ISLAND:
			return [
				{"mesh": _palm_mesh(), "count": 6000, "road_gap": 4.0, "radius": 0.3, "scale": Vector2(0.9, 1.5), "sink": 0.2, "max_h": 16.0},
				{"mesh": _jungle_tree_mesh(), "count": 6000, "road_gap": 5.0, "radius": 0.45, "scale": Vector2(0.7, 1.4), "sink": 0.3, "min_h": 5.0, "max_h": 60.0},
				{"mesh": _bush_mesh(), "count": 6000, "road_gap": 3.5, "radius": 0.0, "scale": Vector2(0.6, 1.5), "sink": 0.3, "max_h": 60.0},
				{"mesh": _fern_mesh(), "count": 9000, "road_gap": 2.5, "radius": 0.0, "scale": Vector2(0.6, 1.4), "sink": 0.05, "max_h": 60.0},
				{"mesh": _rock_mesh(Color(0.17, 0.14, 0.13)), "count": 500, "road_gap": 4.0, "radius": 1.0, "scale": Vector2(0.5, 2.5), "sink": 0.5},
			]
		Biome.JUNGLE:
			return [
				{"mesh": _jungle_tree_mesh(), "count": 10000, "road_gap": 5.0, "radius": 0.45, "scale": Vector2(0.7, 1.5), "sink": 0.3},
				{"mesh": _palm_mesh(), "count": 4000, "road_gap": 4.0, "radius": 0.3, "scale": Vector2(0.8, 1.3), "sink": 0.2},
				{"mesh": _bush_mesh(), "count": 9000, "road_gap": 3.5, "radius": 0.0, "scale": Vector2(0.6, 1.6), "sink": 0.3},
				{"mesh": _fern_mesh(), "count": 14000, "road_gap": 2.5, "radius": 0.0, "scale": Vector2(0.6, 1.5), "sink": 0.05},
				{"mesh": _rock_mesh(Color(0.25, 0.3, 0.22)), "count": 300, "road_gap": 4.0, "radius": 1.0, "scale": Vector2(0.5, 2.2), "sink": 0.5},
			]
		Biome.SNOW:
			return [
				{"mesh": _pine_mesh(true), "count": 5000, "road_gap": 4.0, "radius": 0.35, "scale": Vector2(0.7, 1.5), "sink": 0.3},
				{"mesh": _rock_mesh(Color(0.32, 0.32, 0.36)), "count": 300, "road_gap": 4.0, "radius": 1.0, "scale": Vector2(0.5, 2.5), "sink": 0.5},
			]
		_:
			return [
				{"mesh": _pine_mesh(false), "count": 6000, "road_gap": 4.0, "radius": 0.35, "scale": Vector2(0.7, 1.5), "sink": 0.3},
			]


# ---------- Road path ----------

func _control_points() -> Array[Vector3]:
	var pts: Array[Vector3] = []
	var path := get_node_or_null("RoadPath") as Path3D
	if path and path.curve and path.curve.point_count >= 4:
		for i in path.curve.point_count:
			pts.append(path.transform * path.curve.get_point_position(i))
	else:
		for p in road_points:
			pts.append(_to_world(p))
	return pts


func _build_road_path() -> void:
	var pts := _control_points()
	var n := pts.size()
	var dense: Array[Vector3] = []
	for i in n:
		var p0 := pts[(i - 1 + n) % n]
		var p1 := pts[i]
		var p2 := pts[(i + 1) % n]
		var p3 := pts[(i + 2) % n]
		for s in 40:
			var t := s / 40.0
			dense.append(0.5 * (2.0 * p1 + (p2 - p0) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t * t
				+ (3.0 * p1 - p0 - 3.0 * p2 + p3) * t * t * t))
	dense.append(dense[0])

	samples.clear()
	distances.clear()
	samples.append(dense[0])
	distances.append(0.0)
	var travelled := 0.0
	var next_at := SAMPLE_SPACING
	for i in range(1, dense.size()):
		var a := dense[i - 1]
		var b := dense[i]
		var seg := a.distance_to(b)
		while travelled + seg >= next_at:
			var p := a.lerp(b, (next_at - travelled) / seg)
			if p.distance_to(samples[0]) > SAMPLE_SPACING * 0.5 or next_at < 10.0:
				samples.append(p)
				distances.append(next_at)
			next_at += SAMPLE_SPACING
		travelled += seg

	# Smooth the heights so slopes change gradually (control points can be far apart in height)
	var count := samples.size()
	for pass_i in 3:
		var ys := PackedFloat32Array()
		ys.resize(count)
		for i in count:
			var total := 0.0
			for o in range(-10, 11):
				total += samples[(i + o + count) % count].y
			ys[i] = total / 21.0
		for i in count:
			var p := samples[i]
			p.y = ys[i]
			samples[i] = p

	tangents.resize(count)
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for i in count:
		tangents[i] = (samples[(i + 1) % count] - samples[(i - 1 + count) % count]).normalized()
		lo = lo.min(Vector2(samples[i].x, samples[i].z))
		hi = hi.max(Vector2(samples[i].x, samples[i].z))
	_road_center = (lo + hi) * 0.5
	_origin = _road_center - Vector2.ONE * map_size * 0.5


func _to_world(p: Vector3) -> Vector3:
	return Vector3(p.x, p.z * road_height_scale, p.y)


func _right(i: int) -> Vector3:
	return tangents[i].cross(Vector3.UP).normalized()


# ---------- Spatial lookup (nearest road sample) ----------

func _build_lookup() -> void:
	_cells.clear()
	for i in range(0, samples.size(), 2):
		var key := Vector2i(floori(samples[i].x / LOOKUP_CELL), floori(samples[i].z / LOOKUP_CELL))
		if not _cells.has(key):
			_cells[key] = PackedInt32Array()
		_cells[key].append(i)
	_coarse.clear()
	for i in range(0, samples.size(), 20):
		_coarse.append(i)


# Sets _nearest_dist / _nearest_index. Search radius is about 2 cells (36 m), INF beyond.
func _find_nearest(x: float, z: float) -> void:
	_nearest_dist = INF
	var cx := floori(x / LOOKUP_CELL)
	var cz := floori(z / LOOKUP_CELL)
	var best := INF
	for dz in range(-2, 3):
		for dx in range(-2, 3):
			var key := Vector2i(cx + dx, cz + dz)
			if not _cells.has(key):
				continue
			for i in _cells[key]:
				var s := samples[i]
				var d := (s.x - x) * (s.x - x) + (s.z - z) * (s.z - z)
				if d < best:
					best = d
					_nearest_index = i
	if best < INF:
		_nearest_dist = sqrt(best)


# Signed distance to the shoreline: negative on land, positive out at sea
func _shore_distance(x: float, z: float) -> float:
	if island_radius > 0.0:
		var p := Vector2(x, z) - island_center
		return p.length() - _island_r(p)
	return (Vector2(x, z) - _road_center).dot(coast_direction.normalized()) - coast_offset


# ---------- Terrain ----------

func _build_terrain() -> void:
	var noise := FastNoiseLite.new()
	noise.seed = map_seed
	noise.frequency = 0.006
	noise.fractal_octaves = 5
	var ridge := FastNoiseLite.new()
	ridge.seed = map_seed + 1
	ridge.frequency = 0.003
	ridge.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	ridge.fractal_octaves = 4

	var road_half := road_width * 0.5 + verge_width
	_grid_n = int(map_size / terrain_step) + 1
	var n := _grid_n
	_heights.resize(n * n)
	var near_road := PackedFloat32Array()
	near_road.resize(n * n)

	for iz in n:
		for ix in n:
			var x := _origin.x + ix * terrain_step
			var z := _origin.y + iz * terrain_step
			# Base height: inverse-distance average of the road heights, so the land follows the road
			var wsum := 0.0
			var hsum := 0.0
			var far := INF
			for i in _coarse:
				var s := samples[i]
				var d2 := (s.x - x) * (s.x - x) + (s.z - z) * (s.z - z)
				var w := 1.0 / (d2 + 400.0)
				wsum += w
				hsum += s.y * w
				far = minf(far, d2)
			far = sqrt(far)
			var nat := hsum / wsum
			nat += noise.get_noise_2d(x, z) * hill_height * (0.4 + 0.6 * smoothstep(0.0, 60.0, far))
			var peaks := mountain_height * smoothstep(40.0, 450.0, far) * (0.45 + 0.55 * (ridge.get_noise_2d(x, z) * 0.5 + 0.5))
			if terrace_step > 0.0:
				# flat layers with a short steep step between them, like desert mesas
				var layer := floorf(peaks / terrace_step)
				peaks = (layer + smoothstep(0.75, 1.0, peaks / terrace_step - layer)) * terrace_step
			nat += peaks
			nat += _volcano(x, z, noise)
			if sea_enabled:
				# land slopes down to a shallow lagoon (about 1.5 m deep, where the water is turquoise), then the open sea
				var shore := _shore_distance(x, z)
				nat = lerpf(nat, sea_level - lagoon_depth, smoothstep(-45.0, 0.0, shore))
				nat = lerpf(nat, sea_level - 25.0, smoothstep(60.0, 160.0, shore))
			if lake_radius > 0.0:
				# flat shore 1 m above the lake all around it, easing back into the hills further out (the road is laid
				# over this, the water itself is dug in _carve_ponds, also under the road where it becomes a bridge)
				var dl := Vector2(x, z).distance_to(lake_center)
				var rl := _lake_r(Vector2(x, z))
				if dl < rl * 1.4:
					nat = lerpf(lake_level + 1.0, maxf(nat, lake_level + 1.0), smoothstep(rl, rl * 1.4, dl))

			_find_nearest(x, z)
			var h := nat
			if _nearest_dist < INF:
				# flat just under the road, and over the end of its rounded shoulder (which dips to -0.45 m, 3 m out)
				var blend := smoothstep(road_half + 3.5, road_half + 28.0, _nearest_dist)
				h = lerpf(samples[_nearest_index].y - 0.35, nat, blend)
			_heights[iz * n + ix] = h
			near_road[iz * n + ix] = _nearest_dist

	_ponds.clear()
	if ponds_enabled or lake_radius > 0.0:
		_place_ponds()
		_carve_ponds()

	var pal := _palette()
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	verts.resize(n * n)
	normals.resize(n * n)
	colors.resize(n * n)
	for iz in n:
		for ix in n:
			var i := iz * n + ix
			var x := _origin.x + ix * terrain_step
			var z := _origin.y + iz * terrain_step
			verts[i] = Vector3(x, _heights[i], z)
			var hl := _heights[iz * n + maxi(ix - 1, 0)]
			var hr := _heights[iz * n + mini(ix + 1, n - 1)]
			var hd := _heights[maxi(iz - 1, 0) * n + ix]
			var hu := _heights[mini(iz + 1, n - 1) * n + ix]
			var normal := Vector3(hl - hr, 2.0 * terrain_step, hd - hu).normalized()
			normals[i] = normal
			var c: Color = pal.ground.lerp(pal.ground_alt, clampf(noise.get_noise_2d(x * 3.0, z * 3.0) * 0.5 + 0.5, 0.0, 1.0))
			c = c.lerp(pal.steep, smoothstep(0.75, 0.55, normal.y))
			if volcano_height > 0.0:
				c = c.lerp(pal.get("volcanic", pal.steep), smoothstep(volcano_height * 0.3, volcano_height * 0.5, _heights[i]))
			if sea_enabled:
				c = c.lerp(pal.beach, 1.0 - smoothstep(sea_level + 1.0, sea_level + 1.0 + beach_height, _heights[i]))
			c = c.lerp(pal.beach, _pond_bank(x, z, _heights[i]))
			c = c.lerp(pal.verge, 1.0 - smoothstep(road_half, road_half + 6.0, near_road[i]))
			colors[i] = c

	var indices := PackedInt32Array()
	for iz in n - 1:
		for ix in n - 1:
			var a := iz * n + ix
			indices.append_array([a, a + 1, a + n, a + 1, a + n + 1, a + n])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.95
	mesh.surface_set_material(0, mat)

	_add_static_mesh("Terrain", mesh)


func _terrain_height(x: float, z: float) -> float:
	var fx := clampf((x - _origin.x) / terrain_step, 0.0, _grid_n - 1.001)
	var fz := clampf((z - _origin.y) / terrain_step, 0.0, _grid_n - 1.001)
	var ix := int(fx)
	var iz := int(fz)
	var tx := fx - ix
	var tz := fz - iz
	var n := _grid_n
	var h0 := lerpf(_heights[iz * n + ix], _heights[iz * n + ix + 1], tx)
	var h1 := lerpf(_heights[(iz + 1) * n + ix], _heights[(iz + 1) * n + ix + 1], tx)
	return lerpf(h0, h1, tz)


# ---------- Road ----------

func _build_road_mesh() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var half := road_width * 0.5 + verge_width
	var count := samples.size()
	# Per row, from left to right: hidden skirt, rounded shoulder, road edge, center, road edge, rounded shoulder, hidden skirt.
	# The shoulder eases down 30 cm (to the terrain level next to the road) over 2.5 m, so driving back onto
	# the road is a gentle slope instead of a step. UV.x = meters from center, UV.y = distance along the road.
	var shoulder := [1.0, 2.0, 3.0]
	var lateral := [-half - 3.8]
	var drop := [-1.2]
	# on a bridge the shoulders fold under the deck edge instead: it gets a straight side, like a beam
	var deck_drop := [-1.1]
	for k in range(shoulder.size() - 1, -1, -1):
		lateral.append(-half - shoulder[k])
		drop.append(_shoulder_drop(shoulder[k] / shoulder[-1]))
		deck_drop.append(-0.3 * (k + 1))
	lateral.append_array([-half, 0.0, half])
	drop.append_array([0.0, 0.0, 0.0])
	deck_drop.append_array([0.0, 0.0, 0.0])
	for k in shoulder.size():
		lateral.append(half + shoulder[k])
		drop.append(_shoulder_drop(shoulder[k] / shoulder[-1]))
		deck_drop.append(-0.3 * (k + 1))
	lateral.append(half + 3.8)
	drop.append(-1.2)
	deck_drop.append(-1.1)
	var weights := _surface_weights()
	for i in count + 1:
		var k := i % count
		var c := samples[k]
		var r := _right(k)
		var dist: float = distances[k] if i < count else distances[count - 1] + SAMPLE_SPACING
		var w: Color = weights[k]
		for j in lateral.size():
			var lat: float = lateral[j]
			if absf(lat) > half:
				lat = lerpf(lat, signf(lat) * (half + 0.3), w.b)
			st.set_uv(Vector2(clampf(lat, -half, half), dist))
			st.set_color(w)
			st.add_vertex(c + r * lat + Vector3.UP * lerpf(drop[j], deck_drop[j], w.b))
	var row := lateral.size()
	for i in count:
		for j in row - 1:
			var a := i * row + j
			st.add_index(a)
			st.add_index(a + row)
			st.add_index(a + 1)
			st.add_index(a + 1)
			st.add_index(a + row)
			st.add_index(a + row + 1)
	st.generate_normals()
	var mesh := st.commit()

	var pal := _palette()
	var mat := ShaderMaterial.new()
	mat.shader = _road_shader()
	mat.set_shader_parameter("half_width", road_width * 0.5)
	mat.set_shader_parameter("verge_color", pal.road_verge)
	mat.set_shader_parameter("asphalt_color", pal.asphalt)
	if biome == Biome.DESERT:
		mat.set_shader_parameter("dirt_color", Color(0.62, 0.45, 0.3))
	elif biome == Biome.SNOW:
		mat.set_shader_parameter("dirt_color", Color(0.55, 0.55, 0.6))
	elif biome == Biome.JUNGLE:
		mat.set_shader_parameter("dirt_color", Color(0.5, 0.25, 0.14))
	elif biome == Biome.ISLAND:
		mat.set_shader_parameter("dirt_color", Color(0.45, 0.3, 0.18))
		mat.set_shader_parameter("sand_color", Color(0.96, 0.8, 0.46))
	mesh.surface_set_material(0, mat)
	_add_static_mesh("Road", mesh)


# Per road sample: r = dirt, g = sand, b = bridge planks (asphalt is what is left), with 16 m blends
# between stretches. Also fills _bridge: the samples where the road runs over water.
func _surface_weights() -> PackedColorArray:
	var count := samples.size()
	var dirt := PackedFloat32Array()
	var sand := PackedFloat32Array()
	dirt.resize(count)
	sand.resize(count)
	if surface == Surface.DIRT:
		dirt.fill(1.0)
	elif surface == Surface.SAND:
		sand.fill(1.0)
	var pts := _control_points()
	for sec in surface_sections:
		var i := _nearest_sample(pts[int(sec.x) % pts.size()])
		var to := _nearest_sample(pts[int(sec.y) % pts.size()])
		for guard in count:
			if int(sec.z) == 1:
				dirt[i] = 1.0
				sand[i] = 0.0
			elif int(sec.z) == 2:
				sand[i] = 1.0
				dirt[i] = 0.0
			if i == to:
				break
			i = (i + 1) % count

	_bridge.resize(count)
	_bridge.fill(0)
	for i in count:
		var s := samples[i]
		if _terrain_height(s.x, s.z) < s.y - 1.5:
			for o in range(-4, 5):
				_bridge[(i + o + count) % count] = 1

	var weights := PackedColorArray()
	weights.resize(count)
	const BLUR := 4
	for i in count:
		var d := 0.0
		var sa := 0.0
		var b := 0.0
		for o in range(-BLUR, BLUR + 1):
			var k := (i + o + count) % count
			d += dirt[k]
			sa += sand[k]
			b += _bridge[k]
		var n := 2.0 * BLUR + 1.0
		b /= n
		weights[i] = Color(d / n * (1.0 - b), sa / n * (1.0 - b), b)
	return weights


func _nearest_sample(p: Vector3) -> int:
	_find_nearest(p.x, p.z)
	return _nearest_index


# 0 at the road edge, -0.45 m at the end of the shoulder, with a smooth (cosine) curve in between
func _shoulder_drop(t: float) -> float:
	return -0.45 * (1.0 - cos(PI * clampf(t, 0.0, 1.0))) * 0.5


func _road_shader() -> Shader:
	var shader := Shader.new()
	shader.code = """
shader_type spatial;

uniform float half_width = 4.5;
uniform vec3 sand_color : source_color = vec3(0.78, 0.64, 0.42);
uniform vec3 plank_color : source_color = vec3(0.36, 0.23, 0.13);
uniform vec3 asphalt_color : source_color = vec3(0.12, 0.11, 0.13);
uniform vec3 dirt_color : source_color = vec3(0.34, 0.25, 0.17);
uniform vec3 verge_color : source_color = vec3(0.22, 0.19, 0.15);
uniform vec3 line_color : source_color = vec3(0.95, 0.93, 0.88);
uniform vec3 center_color : source_color = vec3(1.0, 0.72, 0.2);
uniform float dash_length = 6.0;
uniform float line_glow = 0.5;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void fragment() {
	// COLOR (set per road sample): r = dirt, g = sand, b = bridge planks, the rest is asphalt
	float w_dirt = COLOR.r;
	float w_sand = COLOR.g;
	float w_plank = COLOR.b;
	float ax = abs(UV.x);
	float grain = hash(floor(UV * 5.0));

	vec3 col = asphalt_color * (0.85 + 0.3 * grain);
	float edge = step(half_width - 0.5, ax) * step(ax, half_width - 0.3);
	float center = step(ax, 0.1) * step(fract(UV.y / (dash_length * 2.0)), 0.5);
	float line = max(edge, center);
	vec3 lc = center > 0.5 ? center_color : line_color;

	// dirt track: two darker wheel ruts
	vec3 dirt_col = dirt_color * (0.85 + 0.3 * grain) * (1.0 - 0.18 * smoothstep(0.7, 0.0, abs(ax - 1.7)));
	// sand: pale, with soft ripples across the road and faint ruts
	float ripple = sin(UV.y * 1.7 + sin(UV.x * 0.8) * 1.5) * 0.5 + 0.5;
	vec3 sand_col = sand_color * (0.9 + 0.1 * grain) * (0.93 + 0.07 * ripple) * (1.0 - 0.1 * smoothstep(0.7, 0.0, abs(ax - 1.7)));
	// planks across the deck, each a slightly different shade, with dark gaps
	float plank = floor(UV.y / 0.7);
	vec3 plank_col = plank_color * (0.75 + 0.35 * hash(vec2(plank, 3.1))) * mix(0.45, 1.0, step(0.1, fract(UV.y / 0.7)));

	col = mix(col, dirt_col, w_dirt);
	col = mix(col, sand_col, w_sand);
	col = mix(col, plank_col, w_plank);
	line *= 1.0 - clamp(w_dirt + w_sand + w_plank, 0.0, 1.0);

	float verge = smoothstep(half_width, half_width + 0.2, ax);
	vec3 verge_col = mix(verge_color * (0.8 + 0.4 * grain), plank_color * 0.55, w_plank);
	col = mix(col, verge_col, verge);
	line *= 1.0 - verge;
	ALBEDO = mix(col, lc, line);
	EMISSION = lc * line * line_glow;
	ROUGHNESS = mix(0.8, 0.95, clamp(w_dirt + w_sand + w_plank, 0.0, 1.0));
}
"""
	return shader


# ---------- Finish line ----------

func finish_index() -> int:
	return (clampi(spawn_sample, 0, samples.size() - 1) + finish_offset) % samples.size()


# Checkered strip painted across the road, under a thin white neon gantry (visual only, no collision)
func _build_finish_line() -> void:
	var i := finish_index()
	var forward := tangents[i]
	var right := _right(i)
	var up := right.cross(forward).normalized()
	var basis := Basis(-right, up, forward)   # right-handed (Basis(right, up, forward) would be mirrored and hide the top face)
	var origin := samples[i]

	var checker := Shader.new()
	checker.code = """
shader_type spatial;
void fragment() {
	vec2 cell = floor(UV * vec2(14.0, 2.0));
	float white = mod(cell.x + cell.y, 2.0);
	ALBEDO = mix(vec3(0.04), vec3(0.92), white);
	EMISSION = vec3(0.25) * white;
	ROUGHNESS = 0.8;
}
"""
	var strip_mat := ShaderMaterial.new()
	strip_mat.shader = checker
	var strip := PlaneMesh.new()
	strip.size = Vector2(road_width, 1.6)
	strip.material = strip_mat
	var strip_node := MeshInstance3D.new()
	strip_node.name = "FinishLine"
	strip_node.mesh = strip
	strip_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_generated.add_child(strip_node)
	strip_node.global_transform = Transform3D(basis, origin + up * 0.03)

	var neon := StandardMaterial3D.new()
	neon.albedo_color = Color(1, 1, 1)
	neon.emission_enabled = true
	neon.emission = Color(1, 0.98, 0.94)
	neon.emission_energy_multiplier = 2.0
	var span := road_width * 0.5 + verge_width + 0.8
	var height := 5.0
	for side in [-1.0, 1.0]:
		var post := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.12, height, 0.12)
		box.material = neon
		post.mesh = box
		_generated.add_child(post)
		post.global_transform = Transform3D(basis, origin + right * side * span + up * height * 0.5)
	var bar := MeshInstance3D.new()
	var bar_box := BoxMesh.new()
	bar_box.size = Vector3(span * 2.0 + 0.12, 0.1, 0.12)
	bar_box.material = neon
	bar.mesh = bar_box
	bar.name = "FinishGantry"
	_generated.add_child(bar)
	bar.global_transform = Transform3D(basis, origin + up * height)


# ---------- Guardrails ----------

func _build_guardrails() -> void:
	var count := samples.size()
	var curvature := PackedFloat32Array()
	curvature.resize(count)
	for i in count:
		var a := tangents[(i - 3 + count) % count]
		var b := tangents[(i + 3) % count]
		# positive = turning left (counter-clockwise seen from above)
		curvature[i] = a.signed_angle_to(b, Vector3.UP) / (6.0 * SAMPLE_SPACING)

	# Flag tight corners, then widen each run so the rail starts before the corner and ends after it
	var flagged := PackedByteArray()
	flagged.resize(count)
	for i in count:
		if _bridge[i]:
			continue   # bridges have their own railings
		if absf(curvature[i]) > guardrail_curvature:
			for o in range(-12, 13):
				flagged[(i + o + count) % count] = 1
	for i in count:
		if _bridge[i]:
			flagged[i] = 0

	var rail_st := SurfaceTool.new()
	rail_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var neon_st := SurfaceTool.new()
	neon_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var posts: Array[Transform3D] = []
	var body := StaticBody3D.new()
	body.name = "GuardrailCollision"
	_generated.add_child(body)

	var offset := road_width * 0.5 + verge_width * 0.6
	var idx := 0
	while idx < count:
		if not flagged[idx]:
			idx += 1
			continue
		var start := idx
		while idx < count and flagged[idx]:
			idx += 1
		var run := range(start, idx)
		if run.size() < 15:
			continue
		# a run can span several corners: put the rail on the outside of the dominant one
		var total := 0.0
		for k in run:
			total += curvature[k]
		var outer := -1.0 if total > 0.0 else 1.0
		var points: Array[Vector3] = []
		for k in run:
			points.append(samples[k] + _right(k) * outer * offset)
		_add_ribbon(rail_st, points, 0.5, 0.85)
		_add_ribbon(neon_st, points, 0.86, 0.9)
		for p in range(0, points.size(), 2):
			posts.append(Transform3D(Basis(), points[p] + Vector3.UP * 0.45))
		for p in range(0, points.size() - 2, 2):
			var a := points[p]
			var b := points[p + 2]
			var shape := CollisionShape3D.new()
			var box := BoxShape3D.new()
			box.size = Vector3(0.3, 1.3, a.distance_to(b) + 0.1)
			shape.shape = box
			body.add_child(shape)
			shape.global_transform = Transform3D(Basis.looking_at(b - a, Vector3.UP), (a + b) * 0.5 + Vector3.UP * 0.65)

	if posts.is_empty():
		return
	var metal := StandardMaterial3D.new()
	metal.albedo_color = Color(0.7, 0.72, 0.75)
	metal.metallic = 0.8
	metal.roughness = 0.35
	metal.cull_mode = BaseMaterial3D.CULL_DISABLED
	var neon := StandardMaterial3D.new()
	neon.albedo_color = Color(0.1, 0.9, 1.0)
	neon.emission_enabled = true
	neon.emission = Color(0.1, 0.9, 1.0)
	neon.emission_energy_multiplier = 2.5
	neon.cull_mode = BaseMaterial3D.CULL_DISABLED

	rail_st.generate_normals()
	neon_st.generate_normals()
	var rail_mesh := rail_st.commit()
	rail_mesh.surface_set_material(0, metal)
	neon_st.commit(rail_mesh)
	rail_mesh.surface_set_material(1, neon)
	var rail := MeshInstance3D.new()
	rail.name = "Guardrails"
	rail.mesh = rail_mesh
	_generated.add_child(rail)

	var post_mesh := BoxMesh.new()
	post_mesh.size = Vector3(0.12, 0.9, 0.12)
	post_mesh.material = metal
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = post_mesh
	mm.instance_count = posts.size()
	for p in posts.size():
		mm.set_instance_transform(p, posts[p])
	var post_instance := MultiMeshInstance3D.new()
	post_instance.name = "GuardrailPosts"
	post_instance.multimesh = mm
	_generated.add_child(post_instance)


# Wooden railings on both sides of every bridge (with the same neon strip as the guardrails), pillars down
# into the water and a cross beam under the deck every 10 m
func _build_bridges() -> void:
	var count := samples.size()
	var first_land := _bridge.find(0)
	if first_land < 0 or not _bridge.has(1):
		return
	var half := road_width * 0.5 + verge_width
	var rail_st := SurfaceTool.new()
	rail_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var neon_st := SurfaceTool.new()
	neon_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var posts: Array[Transform3D] = []
	var pillars: Array[Transform3D] = []
	var beams: Array[Transform3D] = []
	var body := StaticBody3D.new()
	body.name = "BridgeCollision"
	_generated.add_child(body)

	var step := 0
	while step < count:
		if not _bridge[(first_land + step) % count]:
			step += 1
			continue
		var run: Array[int] = []
		while step < count and _bridge[(first_land + step) % count]:
			run.append((first_land + step) % count)
			step += 1
		for side in [-1.0, 1.0]:
			var points: Array[Vector3] = []
			for k in run:
				points.append(samples[k] + _right(k) * side * (half - 0.15))
			_add_ribbon(rail_st, points, 0.45, 0.55)
			_add_ribbon(rail_st, points, 0.9, 1.05)
			_add_ribbon(neon_st, points, 1.06, 1.1)
			for p in range(0, points.size(), 2):
				posts.append(Transform3D(Basis(), points[p] + Vector3.UP * 0.55))
			for p in range(0, points.size() - 2, 2):
				var a := points[p]
				var b := points[p + 2]
				var shape := CollisionShape3D.new()
				var box := BoxShape3D.new()
				box.size = Vector3(0.3, 1.3, a.distance_to(b) + 0.1)
				shape.shape = box
				body.add_child(shape)
				shape.global_transform = Transform3D(Basis.looking_at(b - a, Vector3.UP), (a + b) * 0.5 + Vector3.UP * 0.65)
		for idx in range(2, run.size() - 2, 5):
			var k := run[idx]
			var s := samples[k]
			var r := _right(k)
			if _terrain_height(s.x, s.z) > s.y - 2.0:
				continue   # still over the bank
			beams.append(Transform3D(Basis(r, Vector3.UP, r.cross(Vector3.UP)), s + Vector3.UP * -1.2))
			for side in [-1.0, 1.0]:
				var p: Vector3 = s + r * side * (half - 0.6)
				var ground := _terrain_height(p.x, p.z) - 0.5
				var top := s.y - 1.2
				pillars.append(Transform3D(Basis().scaled(Vector3(1.0, top - ground, 1.0)), Vector3(p.x, (top + ground) * 0.5, p.z)))

	var wood := _flat_material(Color(0.3, 0.19, 0.11))
	wood.cull_mode = BaseMaterial3D.CULL_DISABLED
	var neon := StandardMaterial3D.new()
	neon.albedo_color = Color(0.1, 0.9, 1.0)
	neon.emission_enabled = true
	neon.emission = Color(0.1, 0.9, 1.0)
	neon.emission_energy_multiplier = 2.5
	neon.cull_mode = BaseMaterial3D.CULL_DISABLED
	rail_st.generate_normals()
	neon_st.generate_normals()
	var rail_mesh := rail_st.commit()
	rail_mesh.surface_set_material(0, wood)
	neon_st.commit(rail_mesh)
	rail_mesh.surface_set_material(1, neon)
	var rail := MeshInstance3D.new()
	rail.name = "BridgeRails"
	rail.mesh = rail_mesh
	_generated.add_child(rail)

	var post := BoxMesh.new()
	post.size = Vector3(0.18, 1.1, 0.18)
	var pillar := _cylinder(0.45, 0.45, 1.0, 8)
	var beam := BoxMesh.new()
	beam.size = Vector3(half * 2.0, 0.5, 0.7)
	var dark_wood := _flat_material(Color(0.2, 0.13, 0.08))
	var parts := [[post, posts, wood, "BridgePosts"], [pillar, pillars, dark_wood, "BridgePillars"], [beam, beams, dark_wood, "BridgeBeams"]]
	for part in parts:
		var list: Array[Transform3D] = part[1]
		if list.is_empty():
			continue
		var mesh: PrimitiveMesh = part[0]
		mesh.material = part[2]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mesh
		mm.instance_count = list.size()
		for i in list.size():
			mm.set_instance_transform(i, list[i])
		var inst := MultiMeshInstance3D.new()
		inst.name = part[3]
		inst.multimesh = mm
		_generated.add_child(inst)


func _add_ribbon(st: SurfaceTool, points: Array[Vector3], bottom: float, top: float) -> void:
	for k in points.size() - 1:
		var a := points[k]
		var b := points[k + 1]
		st.add_vertex(a + Vector3.UP * bottom)
		st.add_vertex(b + Vector3.UP * bottom)
		st.add_vertex(a + Vector3.UP * top)
		st.add_vertex(b + Vector3.UP * bottom)
		st.add_vertex(b + Vector3.UP * top)
		st.add_vertex(a + Vector3.UP * top)


# ---------- Props (trees, cacti, rocks) ----------

func _build_props() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = map_seed
	var forest := FastNoiseLite.new()
	forest.seed = map_seed + 2
	forest.frequency = 0.008
	var road_half := road_width * 0.5 + verge_width
	var body := StaticBody3D.new()
	body.name = "PropCollision"
	_generated.add_child(body)

	var prop_index := 0
	for prop in _props():
		prop_index += 1
		var target := int(prop.count * prop_density)
		var transforms: Array[Transform3D] = []
		var shape_res: CylinderShape3D = null
		if prop.radius > 0.0:
			shape_res = CylinderShape3D.new()
			shape_res.radius = prop.radius
			shape_res.height = 4.0
		var attempts := 0
		while transforms.size() < target and attempts < target * 6:
			attempts += 1
			var x := _origin.x + rng.randf_range(10.0, map_size - 10.0)
			var z := _origin.y + rng.randf_range(10.0, map_size - 10.0)
			if forest.get_noise_2d(x + prop_index * 500.0, z) < -0.15:
				continue
			_find_nearest(x, z)
			if _nearest_dist < road_half + prop.road_gap:
				continue
			var h := _terrain_height(x, z)
			if sea_enabled and h < sea_level + 1.5:
				continue
			if h > prop.get("max_h", INF) or h < prop.get("min_h", -INF):
				continue
			if _in_pond(x, z, 1.15):
				continue
			var slope := absf(_terrain_height(x + 2.0, z) - h) + absf(_terrain_height(x, z + 2.0) - h)
			if slope > 2.5:
				continue
			var s := rng.randf_range(prop.scale.x, prop.scale.y)
			var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s * rng.randf_range(0.8, 1.2), s))
			var pos := Vector3(x, h - prop.sink * s, z)
			transforms.append(Transform3D(basis, pos))
			if shape_res and _nearest_dist < road_half + 25.0:
				var shape := CollisionShape3D.new()
				shape.shape = shape_res
				shape.position = Vector3(x, h + 2.0, z)
				body.add_child(shape)

		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = prop.mesh
		mm.instance_count = transforms.size()
		for i in transforms.size():
			mm.set_instance_transform(i, transforms[i])
		var instance := MultiMeshInstance3D.new()
		instance.name = "Props%d" % prop_index
		instance.multimesh = mm
		_generated.add_child(instance)


func _pine_mesh(snowy: bool) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Three stacked low-poly cones: [bottom radius, height, center y]
	for layer in [[2.4, 4.0, 3.0], [1.8, 3.6, 5.0], [1.1, 3.0, 7.0]]:
		var cone := CylinderMesh.new()
		cone.top_radius = 0.0
		cone.bottom_radius = layer[0]
		cone.height = layer[1]
		cone.radial_segments = 7
		cone.rings = 1
		st.append_from(cone, 0, Transform3D(Basis(), Vector3(0, layer[2], 0)))
	st.generate_normals()
	st.commit(mesh)
	_add_mesh_part(mesh, _cylinder(0.25, 0.15, 2.0, 6), Transform3D(Basis(), Vector3(0, 1.0, 0)))

	var foliage: Material
	if snowy:
		# snow settles on the upward-facing parts of the branches
		var shader := Shader.new()
		shader.code = """
shader_type spatial;
uniform vec3 leaf_color : source_color = vec3(0.07, 0.13, 0.08);
uniform vec3 snow_color : source_color = vec3(0.88, 0.9, 0.96);
varying float up;
void vertex() {
	up = (MODEL_MATRIX * vec4(NORMAL, 0.0)).y;
}
void fragment() {
	ALBEDO = mix(leaf_color, snow_color, smoothstep(0.35, 0.6, up));
	ROUGHNESS = 0.9;
}
"""
		var sm := ShaderMaterial.new()
		sm.shader = shader
		foliage = sm
	else:
		var std := StandardMaterial3D.new()
		std.albedo_color = Color(0.09, 0.15, 0.08)
		std.roughness = 0.9
		foliage = std
	mesh.surface_set_material(0, foliage)
	mesh.surface_set_material(1, _flat_material(Color(0.22, 0.14, 0.09)))
	return mesh


func _jungle_tree_mesh() -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# tall bare trunk with a wide, flat canopy made of three squashed blobs
	for blob in [[Vector3(0, 10.5, 0), 3.2], [Vector3(1.7, 9.5, 0.9), 2.4], [Vector3(-1.4, 9.7, -1.2), 2.5]]:
		var s := SphereMesh.new()
		s.radius = blob[1]
		s.height = blob[1] * 1.1
		s.radial_segments = 7
		s.rings = 3
		st.append_from(s, 0, Transform3D(Basis(), blob[0]))
	st.generate_normals()
	st.commit(mesh)
	_add_mesh_part(mesh, _cylinder(0.4, 0.22, 9.5, 6), Transform3D(Basis(), Vector3(0, 4.75, 0)))
	mesh.surface_set_material(0, _flat_material(Color(0.07, 0.19, 0.07)))
	mesh.surface_set_material(1, _flat_material(Color(0.25, 0.18, 0.12)))
	return mesh


func _palm_mesh() -> ArrayMesh:
	var mesh := ArrayMesh.new()
	# leaning, slightly curved trunk made of five segments
	var trunk := SurfaceTool.new()
	trunk.begin(Mesh.PRIMITIVE_TRIANGLES)
	var p := Vector3.ZERO
	for i in 5:
		var a := 0.08 + i * 0.07
		var dir := Vector3(sin(a), cos(a), 0)
		trunk.append_from(_cylinder(0.26 - i * 0.025, 0.24 - i * 0.025, 1.7, 6), 0,
			Transform3D(Basis(Vector3.BACK, -a), p + dir * 0.85))
		p += dir * 1.6
	# seven fronds: a part going out and slightly up, then a part drooping down
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for k in 7:
		var yaw := k * TAU / 7.0
		var b1 := Basis(Vector3.UP, yaw) * Basis(Vector3.BACK, 0.25)
		var leaf1 := BoxMesh.new()
		leaf1.size = Vector3(3.0, 0.08, 0.7)
		st.append_from(leaf1, 0, Transform3D(b1, p + b1 * Vector3(1.5, 0, 0)))
		var end1 := p + b1 * Vector3(3.0, 0, 0)
		var b2 := Basis(Vector3.UP, yaw) * Basis(Vector3.BACK, -0.65)
		var leaf2 := BoxMesh.new()
		leaf2.size = Vector3(2.6, 0.06, 0.55)
		st.append_from(leaf2, 0, Transform3D(b2, end1 + b2 * Vector3(1.3, 0, 0)))
	st.generate_normals()
	st.commit(mesh)
	trunk.generate_normals()
	trunk.commit(mesh)
	mesh.surface_set_material(0, _flat_material(Color(0.12, 0.27, 0.08)))
	mesh.surface_set_material(1, _flat_material(Color(0.36, 0.27, 0.18)))
	return mesh


# Low undergrowth that fills the gaps between the trees
func _bush_mesh() -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for blob in [[Vector3(0, 0.7, 0), 1.3], [Vector3(1.0, 0.5, 0.4), 0.9], [Vector3(-0.8, 0.5, -0.5), 1.0]]:
		var s := SphereMesh.new()
		s.radius = blob[1]
		s.height = blob[1] * 1.4
		s.radial_segments = 6
		s.rings = 3
		st.append_from(s, 0, Transform3D(Basis(), blob[0]))
	st.generate_normals()
	st.commit(mesh)
	mesh.surface_set_material(0, _flat_material(Color(0.06, 0.16, 0.05)))
	return mesh


func _fern_mesh() -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for k in 8:
		var yaw := k * TAU / 8.0 + (0.2 if k % 2 else 0.0)
		var b := Basis(Vector3.UP, yaw) * Basis(Vector3.BACK, 0.45 + 0.2 * (k % 2))
		var leaf := BoxMesh.new()
		leaf.size = Vector3(1.4, 0.04, 0.3)
		st.append_from(leaf, 0, Transform3D(b, Vector3(0, 0.15, 0) + b * Vector3(0.7, 0, 0)))
	st.generate_normals()
	st.commit(mesh)
	mesh.surface_set_material(0, _flat_material(Color(0.1, 0.23, 0.07)))
	return mesh


func _cactus_mesh() -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.append_from(_cylinder(0.35, 0.3, 5.0, 7), 0, Transform3D(Basis(), Vector3(0, 2.5, 0)))
	# two arms: a short horizontal piece then a vertical one
	for arm in [[1.0, 2.2, 1.8], [-1.0, 3.0, 1.4]]:
		var side: float = arm[0]
		st.append_from(_cylinder(0.22, 0.22, 0.9, 6), 0,
			Transform3D(Basis(Vector3.FORWARD, PI * 0.5), Vector3(side * 0.6, arm[1], 0)))
		st.append_from(_cylinder(0.22, 0.2, arm[2], 6), 0,
			Transform3D(Basis(), Vector3(side * 1.05, arm[1] + arm[2] * 0.5, 0)))
	st.generate_normals()
	st.commit(mesh)
	mesh.surface_set_material(0, _flat_material(Color(0.22, 0.34, 0.16)))
	return mesh


func _rock_mesh(color: Color) -> ArrayMesh:
	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 1.4
	sphere.radial_segments = 6
	sphere.rings = 3
	var mesh := ArrayMesh.new()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.append_from(sphere, 0, Transform3D(Basis().scaled(Vector3(1.3, 1.0, 0.9)), Vector3.ZERO))
	st.generate_normals()
	st.commit(mesh)
	mesh.surface_set_material(0, _flat_material(color))
	return mesh


func _cylinder(bottom: float, top: float, height: float, segments: int) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.bottom_radius = bottom
	c.top_radius = top
	c.height = height
	c.radial_segments = segments
	c.rings = 1
	return c


func _add_mesh_part(mesh: ArrayMesh, part: Mesh, xform: Transform3D) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.append_from(part, 0, xform)
	st.commit(mesh)


func _flat_material(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.9
	return m


# ---------- Sea and weather ----------

# Cartoon water shared by the sea and the ponds: turquoise in the shallows, deeper blue further down, foam on the edge
func _water_material(depth_range: float) -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = """
shader_type spatial;

uniform sampler2D depth_tex : hint_depth_texture, filter_linear_mipmap;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform vec3 shallow_color : source_color = vec3(0.2, 0.95, 0.85);
uniform vec3 deep_color : source_color = vec3(0.0, 0.48, 0.72);
uniform vec3 foam_color : source_color = vec3(1.0, 1.0, 1.0);
uniform float depth_range = 7.0;
uniform float clarity = 2.5;          // meters of water through which the sand is still visible
uniform float foam_width = 0.9;
uniform float color_bands = 4.0;      // cartoon steps between shallow and deep
uniform float wave_strength = 0.12;
uniform float sky_reflection = 1.0;   // 0 = the water keeps its own color even at grazing angles (no sky mirrored in it)
varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = world_pos.xz;
	float t = TIME;

	// Vertical water depth: height of the surface above the ground seen behind it (from the depth buffer).
	// Measuring along the view ray instead would make shallow water look deep at grazing angles.
	float raw = texture(depth_tex, SCREEN_UV).r;
	vec4 ground = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, raw, 1.0);
	ground.xyz /= ground.w;
	float ground_y = (INV_VIEW_MATRIX * vec4(ground.xyz, 1.0)).y;
	float depth = max(world_pos.y - ground_y, 0.0);

	float d = clamp(depth / depth_range, 0.0, 1.0);
	d = floor(d * color_bands + 0.5) / color_bands;
	vec3 col = mix(shallow_color, deep_color, d);

	// Sand shows through the shallow part
	vec3 under = texture(screen_tex, SCREEN_UV).rgb;
	col = mix(under * shallow_color * 1.6, col, smoothstep(0.0, clarity, depth));

	// Wobbly foam line along the shore
	float wobble = sin(p.x * 0.35 + t * 1.3) * 0.25 + sin(p.y * 0.5 - t * 0.9) * 0.2;
	float foam = 1.0 - step(foam_width + wobble, depth);

	// calmer far away, otherwise the wave pattern repeats visibly toward the horizon
	float strength = wave_strength * mix(0.1, 1.0, 1.0 - smoothstep(60.0, 600.0, length(VERTEX)));
	vec3 n = vec3(
		sin(p.x * 0.11 + t * 1.1) * 0.5 + sin(p.x * 0.37 + p.y * 0.23 + t * 1.8) * 0.3,
		1.0 / strength,
		cos(p.y * 0.13 + t * 0.9) * 0.5 + cos(p.y * 0.41 - p.x * 0.27 + t * 1.5) * 0.3);
	NORMAL = normalize((VIEW_MATRIX * vec4(normalize(n), 0.0)).xyz);

	ALBEDO = mix(col, foam_color, foam);
	// low reflection + a bit of glow: the water keeps its own cartoon color instead of mirroring the sky
	EMISSION = mix(col, foam_color, foam) * 0.35;
	ROUGHNESS = mix(mix(1.0, 0.3, sky_reflection), 0.9, foam);
	SPECULAR = 0.25 * sky_reflection;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("shallow_color", water_shallow_color)
	mat.set_shader_parameter("deep_color", water_deep_color)
	mat.set_shader_parameter("depth_range", depth_range)
	return mat


func _build_sea() -> void:
	var mat := _water_material(water_depth_range)
	mat.set_shader_parameter("foam_width", sea_foam_width)
	mat.set_shader_parameter("sky_reflection", water_reflection)
	var plane := PlaneMesh.new()
	plane.size = Vector2.ONE * map_size * 4.0
	plane.material = mat
	var sea := MeshInstance3D.new()
	sea.name = "Sea"
	sea.mesh = plane
	sea.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Only on the sea side: the land edge of the plane sits a bit inland of the shoreline, hidden under the terrain
	if island_radius > 0.0:
		sea.position = Vector3(island_center.x, sea_level, island_center.y)
	else:
		var dir := coast_direction.normalized()
		var center := _road_center + dir * (coast_offset - 40.0 + plane.size.x * 0.5)
		sea.transform = Transform3D(Basis(Vector3.UP, atan2(dir.x, dir.y)), Vector3(center.x, sea_level, center.y))
	_generated.add_child(sea)


# ---------- Lake and ponds ----------

# The lake (if any) comes first, at a fixed spot and level. Then smaller ponds near the road (visible from it)
# but not on it, without overlaps, on fairly flat ground: their water sits a bit under the lowest point of
# the natural rim so it never spills out.
func _place_ponds() -> void:
	if lake_radius > 0.0:
		_ponds.append({"c": lake_center, "r": lake_radius, "level": lake_level, "lake": true})
	var rng := RandomNumberGenerator.new()
	rng.seed = map_seed + 5
	var road_half := road_width * 0.5 + verge_width
	var wanted := _ponds.size() + (pond_count if ponds_enabled else 0)
	var attempts := 0
	while _ponds.size() < wanted and attempts < pond_count * 300:
		attempts += 1
		var r := rng.randf_range(pond_radius.x, pond_radius.y)
		var x := _origin.x + rng.randf_range(80.0, map_size - 80.0)
		var z := _origin.y + rng.randf_range(80.0, map_size - 80.0)
		_find_nearest(x, z)
		var gap := _nearest_dist - road_half - r * 1.3
		if gap < 6.0 or gap > 90.0:
			continue
		var c := Vector2(x, z)
		var overlaps := false
		for other in _ponds:
			if c.distance_to(other.c) < (r + other.r) * 1.3 + 10.0:
				overlaps = true
				break
		if overlaps:
			continue
		var rim_min := INF
		var rim_max := -INF
		for k in 12:
			var a := k * TAU / 12.0
			var h := _terrain_height(x + cos(a) * r * 1.3, z + sin(a) * r * 1.3)
			rim_min = minf(rim_min, h)
			rim_max = maxf(rim_max, h)
		if rim_max - rim_min > 7.0:
			continue   # too steep a slope, the pond would look like a hole in a hillside
		_ponds.append({"c": c, "r": r, "level": rim_min - 0.4, "lake": false})


# Digs a smooth bowl under each pond: flat bottom in the middle, back to the natural ground further out.
# Around the lake the land is first raised to at least 1 m above the water (a beach all around), so the
# water never runs past the edge of its surface. Roads crossing the lake end up on a bridge (the bowl
# is dug under them too).
func _carve_ponds() -> void:
	var n := _grid_n
	for pond in _ponds:
		var r: float = pond.r
		var reach: float = r * (1.2 if pond.lake else 1.3)
		var ix0 := maxi(floori((pond.c.x - reach - _origin.x) / terrain_step), 0)
		var ix1 := mini(ceili((pond.c.x + reach - _origin.x) / terrain_step), n - 1)
		var iz0 := maxi(floori((pond.c.y - reach - _origin.y) / terrain_step), 0)
		var iz1 := mini(ceili((pond.c.y + reach - _origin.y) / terrain_step), n - 1)
		var bottom: float = pond.level - (lake_depth if pond.lake else pond_depth)
		for iz in range(iz0, iz1 + 1):
			for ix in range(ix0, ix1 + 1):
				var p := Vector2(_origin.x + ix * terrain_step, _origin.y + iz * terrain_step)
				var d := p.distance_to(pond.c)
				var i := iz * n + ix
				var h := _heights[i]
				if pond.lake:
					# only where it is under water: on the dry shore the road keeps its own flat bed
					var rl := _lake_r(p)
					var target := lerpf(bottom, pond.level + 1.0, smoothstep(rl * 0.75, rl, d))
					if target < pond.level:
						_heights[i] = minf(h, target)
				else:
					_heights[i] = minf(h, lerpf(bottom, h, smoothstep(r * 0.55, reach, d)))


# 1 on the low, wet banks around a pond (sand / mud color), 0 elsewhere
func _pond_bank(x: float, z: float, h: float) -> float:
	var bank := 0.0
	for pond in _ponds:
		var d := Vector2(x, z).distance_to(pond.c)
		if pond.lake:
			# only the slope down into the water is sand: the flat shore above stays green (and wooded)
			var rl := _lake_r(Vector2(x, z))
			if d < rl * 1.1:
				bank = maxf(bank, (1.0 - smoothstep(pond.level + 0.2, pond.level + 0.9, h)) * (1.0 - smoothstep(rl, rl * 1.1, d)))
		elif d < pond.r * 1.5:
			bank = maxf(bank, (1.0 - smoothstep(pond.level + 0.3, pond.level + 1.4, h)) * (1.0 - smoothstep(pond.r * 1.2, pond.r * 1.5, d)))
	return bank


# margin is in pond radii. Around the lake, vegetation grows down to the water's edge.
func _in_pond(x: float, z: float, margin: float) -> bool:
	for pond in _ponds:
		var d := Vector2(x, z).distance_to(pond.c)
		if pond.lake:
			if d < _lake_r(Vector2(x, z)) * 1.02 and _terrain_height(x, z) < pond.level + 0.6:
				return true
		elif d < pond.r * margin:
			return true
	return false


# Island radius in the direction of p (relative to island_center): bays and headlands along the coast
func _island_r(p: Vector2) -> float:
	if _island_noise == null:
		_island_noise = FastNoiseLite.new()
		_island_noise.seed = map_seed + 11
		_island_noise.frequency = 0.015
		_island_noise.fractal_octaves = 3
	var dir := p.normalized()
	return island_radius * (1.0 + clampf(_island_noise.get_noise_2d(dir.x * 100.0, dir.y * 100.0) * 0.25, -0.08, 0.08))


# Cone with a flat top hollowed into a crater, and gullies down its sides
func _volcano(x: float, z: float, noise: FastNoiseLite) -> float:
	if volcano_height <= 0.0:
		return 0.0
	var d := Vector2(x, z).distance_to(island_center)
	if d >= volcano_radius:
		return 0.0
	var t := 1.0 - d / volcano_radius
	var cone := minf(volcano_height * pow(t, 1.5), volcano_height * 0.85)
	cone *= 1.0 + noise.get_noise_2d(x * 2.5, z * 2.5) * 0.18
	cone -= volcano_height * 0.16 * (1.0 - smoothstep(volcano_radius * 0.03, volcano_radius * 0.08, d))
	return cone


func _build_crater_glow() -> void:
	var r := volcano_radius * 0.06
	var disc := CylinderMesh.new()
	disc.top_radius = r
	disc.bottom_radius = r
	disc.height = 0.01
	disc.radial_segments = 20
	disc.rings = 1
	var lava := StandardMaterial3D.new()
	lava.albedo_color = Color(1.0, 0.35, 0.08)
	lava.emission_enabled = true
	lava.emission = Color(1.0, 0.3, 0.05)
	lava.emission_energy_multiplier = 4.0
	disc.material = lava
	var glow := MeshInstance3D.new()
	glow.name = "CraterGlow"
	glow.mesh = disc
	glow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	glow.position = Vector3(island_center.x, _terrain_height(island_center.x, island_center.y) + 0.6, island_center.y)
	_generated.add_child(glow)
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.4, 0.1)
	light.light_energy = 3.0
	light.omni_range = r * 3.0
	light.position = glow.position + Vector3.UP * 4.0
	_generated.add_child(light)


# Lake radius in the direction of p: the nominal radius +/- 15 % with smooth bays and points, so the shore isn't a circle
func _lake_r(p: Vector2) -> float:
	if _lake_noise == null:
		_lake_noise = FastNoiseLite.new()
		_lake_noise.seed = map_seed + 9
		_lake_noise.frequency = 0.012
	var dir := (p - lake_center).normalized()
	return lake_radius * (1.0 + clampf(_lake_noise.get_noise_2d(dir.x * 100.0, dir.y * 100.0) * 0.4, -0.15, 0.15))


func _build_ponds_water() -> void:
	var pond_mat := _water_material(pond_depth * 1.6)
	pond_mat.set_shader_parameter("foam_width", 0.5)   # gentle banks: a sea-sized foam line would be a wide white ring
	var lake_mat := _water_material(lake_depth * 1.3)
	lake_mat.set_shader_parameter("foam_width", 0.5)
	for i in _ponds.size():
		var pond: Dictionary = _ponds[i]
		var disc := CylinderMesh.new()
		# the lake's edge hides under its raised shore, a pond's under its natural rim
		disc.top_radius = pond.r * (1.17 if pond.lake else 1.25)
		disc.bottom_radius = disc.top_radius
		disc.height = 0.01
		disc.radial_segments = 48 if pond.lake else 24
		disc.rings = 1
		disc.cap_bottom = false
		disc.material = lake_mat if pond.lake else pond_mat
		var water := MeshInstance3D.new()
		water.name = "Lake" if pond.lake else "Pond%d" % i
		water.mesh = disc
		water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		water.position = Vector3(pond.c.x, pond.level, pond.c.y)
		_generated.add_child(water)


func _build_snowfall() -> void:
	var flake_mat := StandardMaterial3D.new()
	flake_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	flake_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	flake_mat.albedo_color = Color(1, 1, 1, 0.9)
	flake_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE * 0.22
	quad.material = flake_mat

	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	process.emission_box_extents = Vector3(45, 2, 45)
	process.direction = Vector3.DOWN
	process.spread = 15.0
	process.initial_velocity_min = 1.5
	process.initial_velocity_max = 2.5
	process.gravity = Vector3(0.6, -0.8, 0.2)
	process.turbulence_enabled = true
	process.turbulence_noise_strength = 0.6

	_snow = GPUParticles3D.new()
	_snow.name = "Snowfall"
	_snow.top_level = true
	_snow.amount = 6000
	_snow.lifetime = 7.0
	_snow.preprocess = 7.0
	_snow.local_coords = false
	_snow.process_material = process
	_snow.draw_pass_1 = quad
	_snow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_snow.visibility_aabb = AABB(Vector3(-80, -40, -80), Vector3(160, 60, 160))
	_generated.add_child(_snow)


# ---------- Helpers ----------

func _add_static_mesh(node_name: String, mesh: ArrayMesh) -> void:
	var body := StaticBody3D.new()
	body.name = node_name
	_generated.add_child(body)
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	body.add_child(instance)
	var shape := CollisionShape3D.new()
	shape.shape = mesh.create_trimesh_shape()
	body.add_child(shape)


func _place_car() -> void:
	var car_root := get_node_or_null("Car") as Node3D
	if not car_root:
		return
	var i := clampi(spawn_sample, 0, samples.size() - 1)
	var forward := Vector3(tangents[i].x, 0.0, tangents[i].z).normalized()
	# The VehicleBody3D drives along +Z, looking_at points -Z at the target
	car_root.global_transform = Transform3D(Basis.looking_at(-forward, Vector3.UP), samples[i] + Vector3.UP * spawn_height)
	var car := car_root.get_node_or_null("Car")
	if car:
		car.spawn_transform = car.global_transform
		car.snap_camera()
		car.reset_interpolation_all()
