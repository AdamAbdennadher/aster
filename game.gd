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

var state := State.PLAYING:
	set(value):
		state = value
		state_changed.emit(value)
var current_map := ""

var _volumes := {"Master": 0.8, "Music": 0.7, "Engine": 0.8, "SFX": 0.8}
var _fade: ColorRect
var _pause_menu: Node
var _busy := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_setup_audio_buses()
	_load_settings()
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
	if state == State.PLAYING and event is InputEventKey and event.pressed and not event.echo \
			and event.physical_keycode == KEY_ESCAPE:
		pause()


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
	for bus in _volumes:
		_apply_volume(bus)


func _save_settings() -> void:
	var cfg := ConfigFile.new()
	for bus in _volumes:
		cfg.set_value("volume", bus, _volumes[bus])
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
