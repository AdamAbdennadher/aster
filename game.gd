extends Node
## Autoload "Game": screen flow (menu -> map -> pause / game over), black fades between screens,
## audio buses and saved volume settings, controls HUD, low-res 3D scaling.

enum State { MENU, PLAYING, PAUSED, GAME_OVER }

const MENU_SCENE := "res://menu.tscn"
const GAME_OVER_SCENE := "res://ui/game_over.tscn"
const SETTINGS_FILE := "user://settings.cfg"
const PIXEL_ROWS := 360.0      # height of the 3D image in pixels, whatever the window size (matches postfx.gdshader)
const MAPS := [
	{"name": "MOUNTAIN", "scene": "res://mountain.tscn"},
	{"name": "DESERT", "scene": "res://desert.tscn"},
	{"name": "SNOW", "scene": "res://snow.tscn"},
]

signal state_changed(state: State)
signal input_device_changed(gamepad: bool)

var state := State.PLAYING:
	set(value):
		state = value
		state_changed.emit(value)
var current_map := ""
var using_gamepad := false   # last input came from a controller (the HUD shows the matching buttons)

var _volumes := {"Master": 0.8, "Music": 0.7, "Engine": 0.8, "SFX": 0.8}

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


# ---------- Audio ----------

func get_volume(bus: String) -> float:
	return _volumes.get(bus, 1.0)


func set_volume(bus: String, value: float) -> void:
	_volumes[bus] = value
	_apply_volume(bus)
	_save_settings()


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
