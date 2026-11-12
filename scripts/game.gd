extends Node
## Autoload "Game": screen flow (menu -> map -> pause / game over), black fades between screens,
## audio buses and saved volume settings, controls HUD, low-res 3D scaling.

enum State { MENU, PLAYING, PAUSED, GAME_OVER }

const MENU_SCENE := "res://scenes/menu.tscn"
const GAME_OVER_SCENE := "res://ui/game_over.tscn"
const SETTINGS_FILE := "user://settings.cfg"
const RECORDS_FILE := "user://records.cfg"
const RECORDS_KEPT := 5
const PIXEL_ROWS := 540.0      # height of the 3D image in pixels, whatever the window size (matches postfx.gdshader)
const TUNING_DEFAULTS := {
	"engine_power": 300.0,
	"max_steer": 0.8,
	"max_steer_at_speed": 0.35,
	"steer_speed_ref": 30.0,
	"max_turn_rate": 2.2,
	"turn_sharpness": 1.15,
	"steer_time": 0.25,
	"steer_smoothing": 5.0,
	"drift_steer_bonus": 0.35,
	"countersteer_assist": 0.5,
	"front_grip_scale": 1.0,
	"rear_grip_scale": 1.0,
	"handbrake_grip": 0.3,
	"handbrake_brake": 0.4,
	"drift_grip": 0.45,
	"grip_loss_speed": 10.0,
	"grip_recovery_speed": 1.5,
	"drift_min_angle_deg": 8.0,
	"drift_keep_angle_deg": 3.0,
	"drift_exit_time": 0.45,
	"drift_yaw_rate": 2.0,
	"drift_yaw_control": 6.0,
	"drift_traction": 0.8,
	"drift_speed_keep": 0.9,
	"max_drift_angle_deg": 45.0,
	"countersteer_boost": 1.6,
	"boost_fill_time": 4.5,
	"boost_duration": 2.5,
	"boost_accel": 14.0,
	"boost_max_speed_kmh": 230.0,
}
const MAPS := [
	{"name": "MOUNTAIN", "scene": "res://scenes/maps/mountain.tscn"},
	{"name": "DESERT", "scene": "res://scenes/maps/desert.tscn"},
	{"name": "SNOW", "scene": "res://scenes/maps/snow.tscn"},
	{"name": "JUNGLE", "scene": "res://scenes/maps/jungle.tscn"},
	{"name": "ISLAND", "scene": "res://scenes/maps/island.tscn"},
	{"name": "TRAINING", "scene": "res://scenes/maps/training.tscn"},
]

signal state_changed(state: State)
signal input_device_changed(gamepad: bool)
signal race_started                                     # first time over the finish line: the clock runs
signal lap_completed(time: float, rank: int, previous_best: float)   # rank 1 = new record, 0 = not in the top
signal race_reset                                       # car back at the spawn, waiting to cross the line

var state := State.PLAYING:
	set(value):
		state = value
		state_changed.emit(value)
var current_map := ""
var race: Node                # lap timer of the current map (race.gd), null on maps without laps
var using_gamepad := false   # last input came from a controller (the HUD shows the matching buttons)
var tuning := TUNING_DEFAULTS.duplicate()

var _volumes := {"Master": 0.8, "Music": 0.7, "Engine": 0.8, "SFX": 0.8}
var _records := {}           # map scene path -> best lap times (seconds), fastest first

const DISPLAY_MODES := ["windowed", "fullscreen", "exclusive"]
const RESOLUTIONS := [Vector2i(1280, 720), Vector2i(1600, 900), Vector2i(1920, 1080), Vector2i(2560, 1440), Vector2i(3840, 2160)]
# "fullscreen" is a borderless window covering the screen; the resolution only applies in windowed mode
const FPS_LIMITS := [30, 60, 120, 144, 165, 240, 0]   # 0 = unlimited
var display := {"mode": "fullscreen", "resolution": Vector2i(1280, 720), "vsync": true, "max_fps": 0}
var _fade: ColorRect
var _pause_menu: Node
var _busy := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_setup_audio_buses()
	_load_settings()
	_load_records()
	apply_display()
	var layer := CanvasLayer.new()
	layer.layer = 100
	add_child(layer)
	_fade = ColorRect.new()
	_fade.color = Color.BLACK
	_fade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_fade)
	add_child(load("res://ui/hud.gd").new())
	add_child(load("res://ui/race_hud.gd").new())
	get_tree().root.size_changed.connect(_update_3d_scale)
	_update_3d_scale()
	_detect_start_scene.call_deferred()


# Autoloads are ready before the first scene exists, so this runs one frame later
func _detect_start_scene() -> void:
	var scene := get_tree().current_scene
	if scene and scene.scene_file_path == MENU_SCENE:
		state = State.MENU
	elif scene:
		# a map launched directly from the editor (F6)
		current_map = scene.scene_file_path
		state = State.PLAYING
	_fade_to(0.0, 0.6)


func _unhandled_input(event: InputEvent) -> void:
	if state == State.PLAYING and event.is_action_pressed("pause"):
		pause()


func _input(event: InputEvent) -> void:
	var pad := using_gamepad
	if event is InputEventJoypadButton or (event is InputEventJoypadMotion and absf(event.axis_value) > 0.5):
		pad = true
	elif event is InputEventKey or event is InputEventMouseButton:
		pad = false
	if pad != using_gamepad:
		using_gamepad = pad
		input_device_changed.emit(pad)


# ---------- Flow ----------

func play_map(path: String) -> void:
	current_map = path
	_change_scene(path, State.PLAYING)


func restart() -> void:
	if current_map != "":
		_change_scene(current_map, State.PLAYING)


func to_menu() -> void:
	_change_scene(MENU_SCENE, State.MENU)


func pause() -> void:
	get_viewport().set_input_as_handled()
	state = State.PAUSED
	get_tree().paused = true
	_pause_menu = load("res://ui/pause_menu.gd").new()
	add_child(_pause_menu)


func resume() -> void:
	_close_pause_menu()
	get_tree().paused = false
	state = State.PLAYING


func game_over() -> void:
	if state != State.PLAYING:
		return
	state = State.GAME_OVER
	get_tree().current_scene.add_child(load(GAME_OVER_SCENE).instantiate())
	# slow motion as the screen comes in
	var tween := create_tween().set_ignore_time_scale()
	tween.tween_property(Engine, "time_scale", 0.25, 0.8).set_trans(Tween.TRANS_SINE)


func _change_scene(path: String, new_state: State) -> void:
	if _busy:
		return
	_busy = true
	await _fade_to(1.0, 0.45)
	_close_pause_menu()
	get_tree().paused = false
	Engine.time_scale = 1.0
	state = new_state
	get_tree().change_scene_to_file(path)
	# let the new scene generate its terrain before revealing it
	await get_tree().process_frame
	await get_tree().process_frame
	await _fade_to(0.0, 0.7)
	_busy = false


func _close_pause_menu() -> void:
	if is_instance_valid(_pause_menu):
		_pause_menu.queue_free()
	_pause_menu = null


func _fade_to(alpha: float, duration: float) -> void:
	var tween := create_tween().set_ignore_time_scale()
	tween.tween_property(_fade, "color:a", alpha, duration).set_trans(Tween.TRANS_SINE)
	await tween.finished


# The UI renders at full window resolution; only the 3D is rendered small (nearest filtering) for the pixel look
func _update_3d_scale() -> void:
	var h := float(get_window().size.y)
	if h > 0.0:
		get_viewport().scaling_3d_scale = clampf(PIXEL_ROWS / h, 0.1, 1.0)


# ---------- Display ----------

## Resolutions that fit on the current screen
func available_resolutions() -> Array[Vector2i]:
	var screen := DisplayServer.screen_get_size()
	var list: Array[Vector2i] = []
	for r in RESOLUTIONS:
		if r.x <= screen.x and r.y <= screen.y:
			list.append(r)
	if list.is_empty():
		list.append(RESOLUTIONS[0])
	return list


func set_display(key: String, value) -> void:
	display[key] = value
	apply_display()
	_save_settings()


func apply_display() -> void:
	Engine.max_fps = display.max_fps
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if display.vsync else DisplayServer.VSYNC_DISABLED)
	# The editor's embedded game view only allows a fixed window: mode and size are applied when
	# the game runs in its own window (exported game, or embedding turned off in the editor)
	if Engine.is_embedded_in_editor():
		return
	var window := get_window()
	match display.mode:
		"windowed":
			window.mode = Window.MODE_WINDOWED
			var res: Vector2i = display.resolution
			var usable := DisplayServer.screen_get_usable_rect()
			window.size = Vector2i(mini(res.x, usable.size.x), mini(res.y, usable.size.y))
			window.position = usable.position + (usable.size - window.size) / 2
		"exclusive":
			window.mode = Window.MODE_EXCLUSIVE_FULLSCREEN
		_:
			window.mode = Window.MODE_FULLSCREEN
	_update_3d_scale.call_deferred()


# ---------- Lap records ----------

func get_records(map: String) -> Array:
	return _records.get(map, [])


func best_time(map: String) -> float:
	var list := get_records(map)
	return list[0] if not list.is_empty() else INF


## Saves the lap if it makes the top RECORDS_KEPT. Returns its rank (1 = new record), or 0 if it is not in the top.
func add_lap_time(map: String, time: float) -> int:
	var list: Array = get_records(map).duplicate()
	list.append(time)
	list.sort()
	list.resize(mini(list.size(), RECORDS_KEPT))
	_records[map] = list
	var cfg := ConfigFile.new()
	for key in _records:
		cfg.set_value("records", key, _records[key])
	cfg.save(RECORDS_FILE)
	var rank := list.find(time)
	return rank + 1 if rank != -1 else 0


func _load_records() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(RECORDS_FILE) != OK:
		return
	for key in cfg.get_section_keys("records"):
		var map: String = key
		# records saved before the maps moved to scenes/maps/ were keyed by the old path
		if map.count("/") == 2 and not ResourceLoader.exists(map):
			map = "res://scenes/maps/" + map.get_file()
		var merged: Array = _records.get(map, []) + cfg.get_value("records", key, [])
		merged.sort()
		merged.resize(mini(merged.size(), RECORDS_KEPT))
		_records[map] = merged


## m:ss.mmm
func format_time(t: float) -> String:
	var ms := int(round(t * 1000.0))
	return "%d:%02d.%03d" % [ms / 60000, (ms / 1000) % 60, ms % 1000]


# ---------- Audio ----------

func get_volume(bus: String) -> float:
	return _volumes.get(bus, 1.0)


func set_volume(bus: String, value: float) -> void:
	_volumes[bus] = value
	_apply_volume(bus)
	_save_settings()


func set_tuning(key: String, value: float) -> void:
	if not TUNING_DEFAULTS.has(key):
		push_error("Unknown handling tuning parameter: " + key)
		return
	tuning[key] = value
	var car := get_tree().get_first_node_in_group("player_car")
	if car:
		car.call("apply_tuning", key, value)


func reset_tuning() -> void:
	tuning = TUNING_DEFAULTS.duplicate()
	var car := get_tree().get_first_node_in_group("player_car")
	if car:
		for key in tuning:
			car.call("apply_tuning", key, tuning[key])


func _apply_volume(bus: String) -> void:
	var i := AudioServer.get_bus_index(bus)
	if i == -1:
		return
	var v: float = _volumes[bus]
	AudioServer.set_bus_mute(i, v <= 0.001)
	AudioServer.set_bus_volume_db(i, linear_to_db(maxf(v, 0.001)))


func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_FILE) == OK:
		for bus in _volumes:
			_volumes[bus] = cfg.get_value("volume", bus, _volumes[bus])
		for key in display:
			display[key] = cfg.get_value("display", key, display[key])
	for bus in _volumes:
		_apply_volume(bus)


func _save_settings() -> void:
	var cfg := ConfigFile.new()
	for bus in _volumes:
		cfg.set_value("volume", bus, _volumes[bus])
	for key in display:
		cfg.set_value("display", key, display[key])
	cfg.save(SETTINGS_FILE)


func _setup_audio_buses() -> void:
	for bus_name in ["Music", "SFX", "Engine"]:
		if AudioServer.get_bus_index(bus_name) == -1:
			AudioServer.add_bus()
			var i := AudioServer.bus_count - 1
			AudioServer.set_bus_name(i, bus_name)
			AudioServer.set_bus_send(i, "Master")
	var engine := AudioServer.get_bus_index("Engine")
	if AudioServer.get_bus_effect_count(engine) == 0:
		# muffles the engine when lifting off the throttle (cutoff driven by engine_audio.gd)
		var lowpass := AudioEffectLowPassFilter.new()
		lowpass.cutoff_hz = 8000.0
		AudioServer.add_bus_effect(engine, lowpass)
