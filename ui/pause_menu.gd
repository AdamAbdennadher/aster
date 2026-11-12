extends CanvasLayer
## Pause menu (ESC / Start in game): resume / change map / settings / main menu.
## Settings: volumes and display (mode, resolution, vsync, max fps).

const VOLUMES := [["master", "Master"], ["music", "Music"], ["engine", "Engine"], ["effects", "SFX"]]
const TUNING_CONTROLS := [
	{"group": "engine", "key": "engine_power", "label": "acceleration", "min": 100.0, "max": 500.0, "step": 10.0, "digits": 0, "unit": ""},
	{"group": "steering", "key": "max_steer", "label": "low-speed steering", "min": 20.0, "max": 65.0, "step": 1.0, "digits": 0, "unit": "deg", "display_scale": 57.29578},
	{"group": "steering", "key": "max_steer_at_speed", "label": "high-speed steering", "min": 8.0, "max": 40.0, "step": 1.0, "digits": 0, "unit": "deg", "display_scale": 57.29578},
	{"group": "steering", "key": "steer_speed_ref", "label": "speed for steering reduction", "min": 36.0, "max": 180.0, "step": 3.6, "digits": 0, "unit": "km/h", "display_scale": 3.6},
	{"group": "steering", "key": "max_turn_rate", "label": "turn rate", "min": 0.5, "max": 4.0, "step": 0.1, "digits": 1, "unit": ""},
	{"group": "steering", "key": "turn_sharpness", "label": "turn sharpness", "min": 1.0, "max": 1.6, "step": 0.025, "digits": 3, "unit": ""},
	{"group": "steering", "key": "steer_time", "label": "steering response", "min": 0.1, "max": 0.6, "step": 0.025, "digits": 3, "unit": "s"},
	{"group": "steering", "key": "steer_smoothing", "label": "steering smoothing", "min": 1.0, "max": 10.0, "step": 0.5, "digits": 1, "unit": ""},
	{"group": "steering", "key": "drift_steer_bonus", "label": "drift steering bonus", "min": 0.0, "max": 40.0, "step": 1.0, "digits": 0, "unit": "deg", "display_scale": 57.29578},
	{"group": "steering", "key": "countersteer_assist", "label": "countersteer assist", "min": 0.0, "max": 1.0, "step": 0.05, "digits": 2, "unit": ""},
	{"group": "grip", "key": "front_grip_scale", "label": "front wheel grip", "min": 0.5, "max": 2.0, "step": 0.05, "digits": 2, "unit": "x"},
	{"group": "grip", "key": "rear_grip_scale", "label": "rear wheel grip", "min": 0.5, "max": 2.0, "step": 0.05, "digits": 2, "unit": "x"},
	{"group": "grip", "key": "handbrake_grip", "label": "handbrake grip", "min": 0.1, "max": 0.8, "step": 0.025, "digits": 3, "unit": ""},
	{"group": "grip", "key": "handbrake_brake", "label": "handbrake braking", "min": 0.0, "max": 1.0, "step": 0.05, "digits": 2, "unit": ""},
	{"group": "grip", "key": "drift_grip", "label": "drift grip", "min": 0.2, "max": 0.9, "step": 0.025, "digits": 3, "unit": ""},
	{"group": "grip", "key": "grip_loss_speed", "label": "grip loss speed", "min": 1.0, "max": 20.0, "step": 0.5, "digits": 1, "unit": ""},
	{"group": "grip", "key": "grip_recovery_speed", "label": "grip recovery speed", "min": 0.3, "max": 5.0, "step": 0.1, "digits": 1, "unit": ""},
	{"group": "drift", "key": "drift_min_angle_deg", "label": "drift entry angle", "min": 4.0, "max": 20.0, "step": 0.5, "digits": 1, "unit": "deg"},
	{"group": "drift", "key": "drift_keep_angle_deg", "label": "drift exit angle", "min": 1.0, "max": 10.0, "step": 0.5, "digits": 1, "unit": "deg"},
	{"group": "drift", "key": "drift_exit_time", "label": "exit assistance time", "min": 0.1, "max": 0.8, "step": 0.025, "digits": 3, "unit": "s"},
	{"group": "drift", "key": "drift_yaw_rate", "label": "drift rotation", "min": 0.5, "max": 4.0, "step": 0.1, "digits": 1, "unit": ""},
	{"group": "drift", "key": "drift_yaw_control", "label": "drift yaw control", "min": 1.0, "max": 12.0, "step": 0.5, "digits": 1, "unit": ""},
	{"group": "drift", "key": "drift_traction", "label": "drift traction", "min": 0.0, "max": 2.0, "step": 0.05, "digits": 2, "unit": ""},
	{"group": "drift", "key": "drift_speed_keep", "label": "drift speed keep", "min": 0.0, "max": 1.0, "step": 0.05, "digits": 2, "unit": ""},
	{"group": "drift", "key": "max_drift_angle_deg", "label": "max drift angle", "min": 20.0, "max": 60.0, "step": 1.0, "digits": 0, "unit": "deg"},
	{"group": "drift", "key": "countersteer_boost", "label": "countersteer boost", "min": 1.0, "max": 2.5, "step": 0.1, "digits": 1, "unit": ""},
	{"group": "boost", "key": "boost_fill_time", "label": "boost fill time", "min": 1.0, "max": 10.0, "step": 0.25, "digits": 2, "unit": "s"},
	{"group": "boost", "key": "boost_duration", "label": "boost duration", "min": 0.5, "max": 5.0, "step": 0.1, "digits": 1, "unit": "s"},
	{"group": "boost", "key": "boost_accel", "label": "boost acceleration", "min": 0.0, "max": 30.0, "step": 0.5, "digits": 1, "unit": ""},
	{"group": "boost", "key": "boost_max_speed_kmh", "label": "boost speed limit", "min": 120.0, "max": 300.0, "step": 5.0, "digits": 0, "unit": "km/h"},
]

var _root: Control
var _main: VBoxContainer
var _maps: VBoxContainer
var _leaderboard: Control
var _leaderboard_scroll: ScrollContainer
var _leaderboard_rows: VBoxContainer
var _name_panel: VBoxContainer
var _name_button: Control
var _name_field: LineEdit
var _settings: VBoxContainer
var _tuning_panel: Control
var _tuning_sliders: Dictionary = {}
var _opened_from: Control      # button to focus again when coming back to the main panel


func _ready() -> void:
	layer = 60
	process_mode = Node.PROCESS_MODE_ALWAYS

	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_root)
	# blurred game behind the menu, no tint
	var blur := ColorRect.new()
	blur.set_anchors_preset(Control.PRESET_FULL_RECT)
	var blur_mat := ShaderMaterial.new()
	blur_mat.shader = load("res://ui/blur.gdshader")
	blur_mat.set_shader_parameter("amount", 0.0)
	blur.material = blur_mat
	_root.add_child(blur)
	create_tween().tween_method(func(v: float): blur_mat.set_shader_parameter("amount", v), 0.0, 3.0, 0.35).set_trans(Tween.TRANS_SINE)

	_main = _column()
	_main.add_child(_title("paused"))
	_main.add_child(_gap(18))
	var resume := _button("resume", Game.resume)
	_main.add_child(resume)
	var change_map := _button("change map", Callable())
	change_map.get_child(0).pressed.connect(_open.bind(_get_maps, change_map))
	_main.add_child(change_map)
	var leaderboard := _button("leaderboard", Callable())
	leaderboard.get_child(0).pressed.connect(_open.bind(_get_leaderboard, leaderboard))
	_main.add_child(leaderboard)
	var settings := _button("settings", Callable())
	settings.get_child(0).pressed.connect(_open.bind(_get_settings, settings))
	_main.add_child(settings)
	_main.add_child(_button("main menu", Game.to_menu))

	_maps = _column()
	_maps.add_child(_title("change map"))
	_maps.add_child(_gap(18))
	for m in Game.MAPS:
		_maps.add_child(_button(m.name.to_lower(), Game.play_map.bind(m.scene)))
	_maps.add_child(_gap(14))
	_maps.add_child(_button("back", _show_main, 11))
	_maps.visible = false

	_build_leaderboard()

	_settings = _column()
	_settings.add_child(_title("settings"))
	_settings.add_child(_gap(18))
	for v in VOLUMES:
		_settings.add_child(_volume_row(v[0], v[1]))
	_settings.add_child(_gap(10))
	_build_display_rows()
	_settings.add_child(_gap(10))
	if OS.has_feature("editor"):
		var handling_lab := _button("handling lab", Callable(), 13)
		handling_lab.get_child(0).pressed.connect(_open.bind(_get_tuning_panel, handling_lab))
		_settings.add_child(handling_lab)
	_name_button = _button(_name_button_text(), _show_name_panel, 13)
	_settings.add_child(_name_button)
	_settings.add_child(_gap(14))
	_settings.add_child(_button("back", _show_main, 11))
	_settings.visible = false

	_build_name_panel()
	if OS.has_feature("editor"):
		_build_tuning_panel()

	_root.modulate.a = 0.0
	create_tween().tween_property(_root, "modulate:a", 1.0, 0.25)
	resume.get_child(0).grab_focus.call_deferred()


func _unhandled_input(event: InputEvent) -> void:
	if _leaderboard.visible and (event.is_action_pressed("ui_down") or event.is_action_pressed("ui_up")):
		_leaderboard_scroll.scroll_vertical += 40 if event.is_action_pressed("ui_down") else -40
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("pause") or event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		if _name_panel.visible:
			_back_to_settings()
		elif _tuning_panel and _tuning_panel.visible:
			_show_settings()
		elif _settings.visible or _maps.visible or _leaderboard.visible:
			_show_main()
		else:
			Game.resume()


func _build_display_rows() -> void:
	var mode_row := OptionCycle.new()
	mode_row.title = "display"
	var modes: Array[String] = []
	modes.assign(Game.DISPLAY_MODES)
	mode_row.set_options(modes, modes.find(Game.display.mode))
	_settings.add_child(mode_row)

	var res_row := OptionCycle.new()
	res_row.title = "resolution"
	var resolutions := Game.available_resolutions()
	var labels: Array[String] = []
	for r in resolutions:
		labels.append("%d x %d" % [r.x, r.y])
	res_row.set_options(labels, maxi(resolutions.find(Game.display.resolution), 0))
	_settings.add_child(res_row)

	var vsync_row := OptionCycle.new()
	vsync_row.title = "vsync"
	var onoff: Array[String] = ["on", "off"]
	vsync_row.set_options(onoff, 0 if Game.display.vsync else 1)
	_settings.add_child(vsync_row)

	var fps_row := OptionCycle.new()
	fps_row.title = "max fps"
	var fps_labels: Array[String] = []
	for limit in Game.FPS_LIMITS:
		fps_labels.append("unlimited" if limit == 0 else str(limit))
	fps_row.set_options(fps_labels, maxi(Game.FPS_LIMITS.find(Game.display.max_fps), 0))
	fps_row.changed.connect(func(i: int): Game.set_display("max_fps", Game.FPS_LIMITS[i]))
	_settings.add_child(fps_row)

	# the resolution only matters for a window; in fullscreen the game uses the screen's own resolution
	var refresh_res := func(): res_row.set_disabled(Game.display.mode != "windowed")
	refresh_res.call_deferred()
	if Engine.is_embedded_in_editor():
		refresh_res = func(): pass
		(func():
			mode_row.set_disabled(true)
			res_row.set_disabled(true)).call_deferred()
		var note := Label.new()
		note.text = "display and resolution apply when the game runs in its own window"
		note.label_settings = UIStyle.label(8, UIStyle.DIM, 0.0, 400, 1)
		note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_settings.add_child(note)
	mode_row.changed.connect(func(i: int):
		Game.set_display("mode", Game.DISPLAY_MODES[i])
		refresh_res.call())
	res_row.changed.connect(func(i: int): Game.set_display("resolution", resolutions[i]))
	vsync_row.changed.connect(func(i: int): Game.set_display("vsync", i == 0))


func _get_maps() -> Control:
	return _maps


func _get_leaderboard() -> Control:
	_set_leaderboard_message("")
	_leaderboard_scroll.scroll_vertical = 0
	Online.fetch_leaderboard()
	return _leaderboard


# Full-screen page: title at the top, then a scrolling list (each map, then its ranking), back at the bottom
func _build_leaderboard() -> void:
	_leaderboard = Control.new()
	_leaderboard.set_anchors_preset(Control.PRESET_FULL_RECT)
	_leaderboard.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_leaderboard)

	var title := _title("leaderboard")
	title.set_anchors_preset(Control.PRESET_TOP_WIDE)
	title.offset_top = 18
	_leaderboard.add_child(title)

	_leaderboard_scroll = ScrollContainer.new()
	_leaderboard_scroll.anchor_left = 0.5
	_leaderboard_scroll.anchor_right = 0.5
	_leaderboard_scroll.anchor_bottom = 1.0
	_leaderboard_scroll.offset_left = -140
	_leaderboard_scroll.offset_right = 140
	_leaderboard_scroll.offset_top = 76
	_leaderboard_scroll.offset_bottom = -44
	_leaderboard_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_leaderboard_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	_leaderboard.add_child(_leaderboard_scroll)
	_leaderboard_rows = VBoxContainer.new()
	_leaderboard_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_leaderboard_rows.add_theme_constant_override("separation", 3)
	_leaderboard_scroll.add_child(_leaderboard_rows)

	var back := _button("back", _show_main, 11)
	back.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	back.offset_top = -34
	back.offset_bottom = -14
	_leaderboard.add_child(back)

	_leaderboard.visible = false
	Online.leaderboard_loaded.connect(_on_leaderboard_loaded)


func _set_leaderboard_message(text: String) -> void:
	for child in _leaderboard_rows.get_children():
		child.queue_free()
	if text == "":
		return
	var l := Label.new()
	l.text = text
	l.label_settings = UIStyle.label(12, UIStyle.DIM, 0.0, 300, 2)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_leaderboard_rows.add_child(l)


func _on_leaderboard_loaded(rows) -> void:
	if rows == null:
		_set_leaderboard_message("can't reach the leaderboard")
		return
	_set_leaderboard_message("")
	for m in Game.MAPS:
		var map_id := Online.map_id(m.scene)
		var times: Array = rows.filter(func(r): return r.get("map", "") == map_id)
		times.sort_custom(func(a, b): return int(a.get("time_ms", 0)) < int(b.get("time_ms", 0)))

		var header := Label.new()
		header.text = m.name.to_lower()
		header.label_settings = UIStyle.label(14, UIStyle.WHITE, 0.0, 300, 3)
		_leaderboard_rows.add_child(header)
		if times.is_empty():
			_leaderboard_rows.add_child(_leaderboard_line("", "no time yet", "", false))
		for i in times.size():
			var r: Dictionary = times[i]
			_leaderboard_rows.add_child(_leaderboard_line(str(i + 1), str(r.get("player_name", "?")).to_lower(),
				Game.format_time(float(r.get("time_ms", 0)) / 1000.0), r.get("player_id", "") == Online.player_id))
		_leaderboard_rows.add_child(_gap(12))


func _leaderboard_line(place: String, player: String, time: String, mine: bool) -> Control:
	var color := UIStyle.WHITE if mine else UIStyle.DIM
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.add_child(_gap(6))
	var place_label := Label.new()
	place_label.text = place
	place_label.custom_minimum_size = Vector2(14, 0)
	place_label.label_settings = UIStyle.label(10, UIStyle.DIM, 0.0, 400, 1)
	row.add_child(place_label)
	var player_label := Label.new()
	player_label.text = player
	player_label.clip_text = true
	player_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	player_label.label_settings = UIStyle.label(11, color, 0.0, 400, 2)
	row.add_child(player_label)
	var time_label := Label.new()
	time_label.text = time
	time_label.label_settings = UIStyle.label(11, color, 0.0, 300, 2)
	row.add_child(time_label)
	return row


func _get_settings() -> Control:
	return _settings


func _get_tuning_panel() -> Control:
	return _tuning_panel


func _build_tuning_panel() -> void:
	_tuning_panel = Control.new()
	_tuning_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_tuning_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_tuning_panel)

	var title := _title("handling lab")
	title.set_anchors_preset(Control.PRESET_TOP_WIDE)
	title.offset_top = 12
	_tuning_panel.add_child(title)

	var scroll := ScrollContainer.new()
	scroll.anchor_left = 0.5
	scroll.anchor_right = 0.5
	scroll.anchor_bottom = 1.0
	scroll.offset_left = -220
	scroll.offset_right = 220
	scroll.offset_top = 58
	scroll.offset_bottom = -42
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_tuning_panel.add_child(scroll)

	var rows := VBoxContainer.new()
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows.add_theme_constant_override("separation", 6)
	scroll.add_child(rows)

	var previous_group := ""
	for config in TUNING_CONTROLS:
		if config.group != previous_group:
			var heading := Label.new()
			heading.text = config.group
			heading.label_settings = UIStyle.label(13, UIStyle.WHITE, 0.0, 400, 2)
			rows.add_child(heading)
			previous_group = config.group

		var row := VBoxContainer.new()
		row.add_theme_constant_override("separation", 1)
		rows.add_child(row)
		var label_row := HBoxContainer.new()
		row.add_child(label_row)
		var name := Label.new()
		name.text = config.label
		name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name.label_settings = UIStyle.label(9, UIStyle.DIM, 0.0, 400, 1)
		label_row.add_child(name)
		var value_label := Label.new()
		value_label.custom_minimum_size.x = 74
		value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		value_label.label_settings = UIStyle.label(9, UIStyle.WHITE, 0.0, 400, 1)
		label_row.add_child(value_label)

		var slider := HSlider.new()
		slider.min_value = config.min
		slider.max_value = config.max
		slider.step = config.step
		var display_scale: float = config.get("display_scale", 1.0)
		slider.value = float(Game.tuning[config.key]) * display_scale
		slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slider.focus_mode = Control.FOCUS_ALL
		UIStyle.style_slider(slider)
		slider.value_changed.connect(_on_tuning_changed.bind(config.key, value_label, config.digits, config.unit, display_scale))
		row.add_child(slider)
		_tuning_sliders[config.key] = slider
		value_label.text = _format_tuning_value(slider.value, config.digits, config.unit)

	var buttons := HBoxContainer.new()
	buttons.anchor_left = 0.5
	buttons.anchor_right = 0.5
	buttons.anchor_top = 1.0
	buttons.anchor_bottom = 1.0
	buttons.offset_left = -150
	buttons.offset_right = 150
	buttons.offset_top = -36
	buttons.offset_bottom = -12
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 24)
	_tuning_panel.add_child(buttons)
	buttons.add_child(_button("reset values", _reset_tuning_panel, 11))
	buttons.add_child(_button("back", _show_settings, 11))
	_tuning_panel.visible = false


func _on_tuning_changed(value: float, key: String, value_label: Label, digits: int, unit: String, display_scale: float) -> void:
	Game.set_tuning(key, value / display_scale)
	value_label.text = _format_tuning_value(value, digits, unit)


func _format_tuning_value(value: float, digits: int, unit: String) -> String:
	var text := str(roundi(value)) if digits == 0 else ("%.1f" % value if digits == 1 else ("%.2f" % value if digits == 2 else "%.3f" % value))
	return text if unit == "" else text + " " + unit


func _reset_tuning_panel() -> void:
	Game.reset_tuning()
	for config in TUNING_CONTROLS:
		var slider: HSlider = _tuning_sliders[config.key]
		slider.value = float(Game.tuning[config.key]) * float(config.get("display_scale", 1.0))


func _show_settings() -> void:
	_tuning_panel.visible = false
	_main.visible = false
	_settings.visible = true
	if _opened_from:
		_opened_from.get_child(0).grab_focus()


# Shows a sub panel and focuses its first interactive element
func _open(panel_getter: Callable, from: Control) -> void:
	var panel: Control = panel_getter.call()
	_opened_from = from
	_main.visible = false
	if panel != _settings:
		_settings.visible = false
	panel.visible = true
	for child in panel.get_children():
		var target := _first_focusable(child)
		if target:
			target.grab_focus()
			return


func _first_focusable(node: Node) -> Control:
	if node is Control and node.focus_mode == Control.FOCUS_ALL and node.is_visible_in_tree():
		return node
	for child in node.get_children():
		var found := _first_focusable(child)
		if found:
			return found
	return null


func _name_button_text() -> String:
	return "name  ·  " + Online.player_name if Online.player_name != "" else "name"


func _build_name_panel() -> void:
	_name_panel = _column()
	_name_panel.add_child(_title("name"))
	_name_panel.add_child(_gap(14))
	_name_field = UIStyle.line_edit()
	_name_field.text_submitted.connect(_confirm_name)
	var center := CenterContainer.new()
	center.add_child(_name_field)
	_name_panel.add_child(center)
	_name_panel.add_child(_gap(10))
	_name_panel.add_child(_button("ok", func(): _confirm_name(_name_field.text), 13))
	_name_panel.add_child(_button("back", _back_to_settings, 11))
	_name_panel.visible = false


func _show_name_panel() -> void:
	_settings.visible = false
	_name_panel.visible = true
	_name_field.text = Online.player_name
	_name_field.grab_focus()
	_name_field.select_all()


func _confirm_name(text: String) -> void:
	if text.strip_edges() == "":
		return
	Online.set_player_name(text)
	_name_button.get_child(0).text = _name_button_text()
	_back_to_settings()


func _back_to_settings() -> void:
	_name_panel.visible = false
	_settings.visible = true
	_name_button.get_child(0).grab_focus()


func _show_main() -> void:
	_name_panel.visible = false
	_leaderboard.visible = false
	_settings.visible = false
	_maps.visible = false
	if _tuning_panel:
		_tuning_panel.visible = false
	_main.visible = true
	if _opened_from:
		_opened_from.get_child(0).grab_focus()


func _column() -> VBoxContainer:
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	box.grow_vertical = Control.GROW_DIRECTION_BOTH
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 8)
	_root.add_child(box)
	return box


func _title(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.label_settings = UIStyle.label(34, UIStyle.WHITE, 0.0, 200, 6)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return l


func _gap(h: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	return c


func _button(text: String, action: Callable, size := 15) -> Control:
	var b := NeonButton.new()
	b.text = text
	b.text_size = size
	if action.is_valid():
		b.pressed.connect(action)
	var center := CenterContainer.new()
	center.add_child(b)
	return center


func _volume_row(label_text: String, bus: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var name_label := Label.new()
	name_label.text = label_text
	name_label.custom_minimum_size = Vector2(70, 0)
	name_label.label_settings = UIStyle.label(11, UIStyle.DIM, 0.0, 400, 2)
	row.add_child(name_label)

	var slider := HSlider.new()
	slider.custom_minimum_size = Vector2(140, 12)
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.05
	slider.value = Game.get_volume(bus)
	UIStyle.style_slider(slider)
	row.add_child(slider)

	var value_label := Label.new()
	value_label.custom_minimum_size = Vector2(28, 0)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.label_settings = UIStyle.label(9, UIStyle.DIM, 0.0, 300)
	value_label.text = "%d" % roundi(slider.value * 100.0)
	row.add_child(value_label)

	slider.value_changed.connect(func(v: float):
		Game.set_volume(bus, v)
		value_label.text = "%d" % roundi(v * 100.0)
		name_label.label_settings.font_color = UIStyle.WHITE)
	slider.focus_entered.connect(func(): name_label.label_settings.font_color = UIStyle.WHITE)
	slider.focus_exited.connect(func(): name_label.label_settings.font_color = UIStyle.DIM)
	slider.mouse_entered.connect(func(): name_label.label_settings.font_color = UIStyle.WHITE)
	slider.mouse_exited.connect(func(): if not slider.has_focus(): name_label.label_settings.font_color = UIStyle.DIM)
	return row
