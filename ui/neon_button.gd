class_name NeonButton
extends Button
## Text-only button in thin white: on hover/focus the text eases from dimmed to full white and grows slightly.

@export var text_size := 16
@export var weight := 400
@export var rest_alpha := 0.55

var _hover := 0.0
var _tween: Tween


func _ready() -> void:
	flat = true
	focus_mode = Control.FOCUS_ALL
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	add_theme_font_override("font", UIStyle.font(weight, 2))
	add_theme_font_size_override("font_size", text_size)
	for style in ["normal", "hover", "pressed", "focus", "disabled", "hover_pressed"]:
		add_theme_stylebox_override(style, StyleBoxEmpty.new())
	mouse_entered.connect(_set_hover.bind(true))
	mouse_exited.connect(func(): if not has_focus(): _set_hover(false))
	focus_entered.connect(_set_hover.bind(true))
	focus_exited.connect(_set_hover.bind(false))
	button_down.connect(_punch)
	resized.connect(func(): pivot_offset = size * 0.5)
	pivot_offset = size * 0.5
	_apply()


func _set_hover(on: bool) -> void:
	if _tween:
		_tween.kill()
	_tween = create_tween().set_ignore_time_scale()
	_tween.tween_method(_set_amount, _hover, 1.0 if on else 0.0, 0.25).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func _set_amount(value: float) -> void:
	_hover = value
	_apply()


func _apply() -> void:
	var c := Color(UIStyle.WHITE, lerpf(rest_alpha, 1.0, _hover))
	for key in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]:
		add_theme_color_override(key, c)
	scale = Vector2.ONE * (1.0 + 0.05 * _hover)


func _punch() -> void:
	var t := create_tween().set_ignore_time_scale()
	t.tween_property(self, "scale", Vector2.ONE * 0.95, 0.06)
	t.tween_property(self, "scale", Vector2.ONE * (1.0 + 0.05 * _hover), 0.12)
