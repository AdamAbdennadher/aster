extends CanvasLayer
## Pause menu (ESC / Start in game): resume / change map / settings / main menu.
## Settings: volumes and display (mode, resolution, vsync, max fps).

const VOLUMES := [["master", "Master"], ["music", "Music"], ["engine", "Engine"], ["effects", "SFX"]]

var _root: Control
var _main: VBoxContainer
var _maps: VBoxContainer
var _settings: VBoxContainer
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

	_settings = _column()
	_settings.add_child(_title("settings"))
	_settings.add_child(_gap(18))
	for v in VOLUMES:
		_settings.add_child(_volume_row(v[0], v[1]))
	_settings.add_child(_gap(10))
	_build_display_rows()
	_settings.add_child(_gap(14))
	_settings.add_child(_button("back", _show_main, 11))
	_settings.visible = false

	_root.modulate.a = 0.0
	create_tween().tween_property(_root, "modulate:a", 1.0, 0.25)
	resume.get_child(0).grab_focus.call_deferred()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause") or event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		if _settings.visible or _maps.visible:
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


func _get_settings() -> Control:
	return _settings


# Shows a sub panel and focuses its first interactive element
func _open(panel_getter: Callable, from: Control) -> void:
	var panel: Control = panel_getter.call()
	_opened_from = from
	_main.visible = false
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


func _show_main() -> void:
	_settings.visible = false
	_maps.visible = false
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
