extends CanvasLayer
## Game over overlay: darkens the slowed-down game, neon title, RESTART / MENU. R or Enter restarts.

var _root: Control
var _restart: NeonButton


func _ready() -> void:
	layer = 30
	process_mode = Node.PROCESS_MODE_ALWAYS

	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_root)

	var shade := ColorRect.new()
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.color = Color(0.03, 0.01, 0.06, 0.7)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(shade)

	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	box.grow_vertical = Control.GROW_DIRECTION_BOTH
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 6)
	_root.add_child(box)

	var title := Label.new()
	title.text = "game over"
	title.label_settings = UIStyle.label(52, UIStyle.RED, 0.0, 200, 6)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	var sub := Label.new()
	sub.text = "the car is on its roof"
	sub.label_settings = UIStyle.label(10, UIStyle.DIM, 0.0, 400, 2)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(sub)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 22)
	box.add_child(spacer)

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 40)
	box.add_child(buttons)
	_restart = _button("restart", Game.restart)
	buttons.add_child(_restart)
	buttons.add_child(_button("menu", Game.to_menu))

	# Fade + slight drop-in
	_root.modulate.a = 0.0
	box.position.y -= 12.0
	var t := create_tween().set_ignore_time_scale().set_parallel()
	t.tween_property(_root, "modulate:a", 1.0, 0.6).set_trans(Tween.TRANS_SINE)
	t.tween_property(box, "position:y", box.position.y + 12.0, 0.8).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_restart.grab_focus.call_deferred()


func _button(text: String, action: Callable) -> NeonButton:
	var b := NeonButton.new()
	b.text = text
	b.text_size = 14
	b.pressed.connect(action)
	return b


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_R:
		Game.restart()
