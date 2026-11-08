class_name OptionCycle
extends HBoxContainer
## Settings row "name   ‹ value ›". Click / A / Enter goes to the next value, left / right cycle both ways.

signal changed(index: int)

var title := ""
var options: Array[String] = []
var index := 0

var _name_label: Label
var _value: NeonButton


func _ready() -> void:
	add_theme_constant_override("separation", 12)
	_name_label = Label.new()
	_name_label.text = title
	_name_label.custom_minimum_size = Vector2(70, 0)
	_name_label.label_settings = UIStyle.label(11, UIStyle.DIM, 0.0, 400, 2)
	add_child(_name_label)

	_value = NeonButton.new()
	_value.text_size = 11
	_value.custom_minimum_size = Vector2(176, 0)
	_value.pressed.connect(_step.bind(1))
	_value.gui_input.connect(_on_value_input)
	_value.focus_entered.connect(func(): _name_label.label_settings.font_color = UIStyle.WHITE)
	_value.focus_exited.connect(func(): _name_label.label_settings.font_color = UIStyle.DIM)
	_value.mouse_entered.connect(func(): _name_label.label_settings.font_color = UIStyle.WHITE)
	_value.mouse_exited.connect(func(): if not _value.has_focus(): _name_label.label_settings.font_color = UIStyle.DIM)
	add_child(_value)
	_refresh()


func set_options(new_options: Array[String], selected: int) -> void:
	options = new_options
	index = clampi(selected, 0, maxi(options.size() - 1, 0))
	if _value:
		_refresh()


func set_disabled(disabled: bool) -> void:
	_value.disabled = disabled
	_value.focus_mode = Control.FOCUS_NONE if disabled else Control.FOCUS_ALL
	modulate.a = 0.35 if disabled else 1.0


func focus_value() -> void:
	_value.grab_focus()


func _on_value_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_left"):
		_step(-1)
		accept_event()
	elif event.is_action_pressed("ui_right"):
		_step(1)
		accept_event()


func _step(direction: int) -> void:
	if options.size() < 2 or _value.disabled:
		return
	index = wrapi(index + direction, 0, options.size())
	_refresh()
	changed.emit(index)


func _refresh() -> void:
	_value.text = "‹   %s   ›" % (options[index] if index < options.size() else "")
