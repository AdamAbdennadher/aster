extends Node
## Autoload "Music": menu track + shuffled in-game playlist with crossfades, and a small "now playing" widget.

const CONFIG := "res://music_config.tres"   # open it in the Inspector to change the tracks

var _menu_track := ""
var _playlist: Array[String] = []
var _crossfade := 2.0
var _volume_db := -6.0

var _players: Array[AudioStreamPlayer] = []
var _active := 0
var _queue: Array[String] = []
var _current := ""
var _last_state := -1
var _widget: Control
var _title: Label
var _widget_tween: Tween


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_load_config()
	for i in 2:
		var p := AudioStreamPlayer.new()
		p.bus = "Music"
		p.volume_db = -80.0
		p.finished.connect(_on_finished.bind(p))
		add_child(p)
		_players.append(p)
	_build_widget()
	Game.state_changed.connect(_on_state_changed)
	# read the state when this runs, not now: the start scene sets it during this frame
	(func(): _on_state_changed(Game.state)).call_deferred()


func _load_config() -> void:
	var cfg: MusicConfig = load(CONFIG)
	if cfg.menu_track:
		_menu_track = cfg.menu_track.resource_path
	for stream in cfg.playlist:
		if stream:
			_playlist.append(stream.resource_path)
	_crossfade = cfg.crossfade
	_volume_db = cfg.volume_db


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("next_track") and Game.state != Game.State.MENU:
		next()


func next() -> void:
	if _playlist.is_empty():
		return
	if _queue.is_empty():
		_queue.assign(_playlist.duplicate())
		_queue.shuffle()
		if _queue[0] == _current and _queue.size() > 1:
			_queue.push_back(_queue.pop_front())
	_play(_queue.pop_front())


func _on_state_changed(state: Game.State) -> void:
	var entering := state != _last_state
	_last_state = state
	if state == Game.State.MENU:
		# arriving on the menu (game launch or back from a run) always starts the menu track from the top
		if entering and _menu_track != "":
			_play(_menu_track)
		_widget.visible = false
	else:
		if _current == _menu_track or _current == "":
			next()
		_widget.visible = true


func _on_finished(player: AudioStreamPlayer) -> void:
	if player != _players[_active]:
		return
	if _current == _menu_track:
		player.play()
	else:
		next()


func _play(path: String) -> void:
	print_verbose("Music: play ", path.get_file())
	_current = path
	var old := _players[_active]
	_active = 1 - _active
	var new := _players[_active]
	new.stream = load(path)
	new.volume_db = -40.0
	new.play()
	var tween := create_tween().set_parallel().set_ignore_time_scale()
	tween.tween_property(new, "volume_db", _volume_db, _crossfade).set_trans(Tween.TRANS_SINE)
	if old.playing:
		tween.tween_property(old, "volume_db", -60.0, _crossfade).set_trans(Tween.TRANS_SINE)
		tween.chain().tween_callback(old.stop)
	if path != _menu_track:
		_show_title(_pretty_name(path))


func _pretty_name(path: String) -> String:
	return path.get_file().get_basename().replace("-", " ").replace("_", " ").to_lower()


# ---------- Now playing widget (bottom left) ----------

func _build_widget() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 40
	add_child(layer)
	_widget = VBoxContainer.new()
	_widget.anchor_top = 1.0
	_widget.anchor_bottom = 1.0
	_widget.offset_left = 12.0
	_widget.offset_top = -24.0
	_widget.offset_bottom = -10.0
	_widget.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_widget.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_widget.add_theme_constant_override("separation", 2)
	layer.add_child(_widget)

	_title = Label.new()
	_title.label_settings = UIStyle.label(10, UIStyle.DIM, 0.0, 400, 1)
	_widget.add_child(_title)


# The widget pops up when a track starts, then dims so it doesn't distract while driving
func _show_title(text: String) -> void:
	_title.text = text
	if _widget_tween:
		_widget_tween.kill()
	_widget.modulate.a = 1.0
	_widget_tween = create_tween().set_ignore_time_scale()
	_widget_tween.tween_interval(4.0)
	_widget_tween.tween_property(_widget, "modulate:a", 0.35, 1.5)
