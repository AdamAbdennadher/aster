extends CanvasLayer
## Pause menu (ESC in game): RESUME / SETTINGS / MAIN MENU. Settings has the volume sliders.

const VOLUMES := [["master", "Master"], ["music", "Music"], ["engine", "Engine"], ["effects", "SFX"]]

var _root: Control
var _main: VBoxContainer
var _settings: VBoxContainer


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
	_main.add_child(_button("resume", Game.resume))
	_main.add_child(_button("settings", _show_settings))
	_main.add_child(_button("main menu", Game.to_menu))

	_settings = _column()
	_settings.add_child(_title("settings"))
	_settings.add_child(_gap(18))
	for v in VOLUMES:
		_settings.add_child(_volume_row(v[0], v[1]))
	_settings.add_child(_gap(14))
	_settings.add_child(_button("back", _show_main, 11))
	_settings.visible = false

	_root.modulate.a = 0.0
	create_tween().tween_property(_root, "modulate:a", 1.0, 0.25)
	_main.get_child(2).get_child(0).grab_focus.call_deferred()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		if _settings.visible:
			_show_main()
		else:
			Game.resume()


func _show_settings() -> void:
	_main.visible = false
	_settings.visible = true
	_settings.get_child(2).get_child(1).grab_focus()


func _show_main() -> void:
	_settings.visible = false
	_main.visible = true
	_main.get_child(3).get_child(0).grab_focus()


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
