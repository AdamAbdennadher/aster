extends Node3D
## Title screen + map select. The desert map is the backdrop, the car is parked facing the sunset,
## the UI sits on the right. PLAY turns the same screen into the map select (no scene change).

const IDLE_SOUND := "res://sounds/motor/motor-menu.mp3"
const CAR_SAMPLE := 150                     # where the car is parked along the desert road
const CAR_HEADING := Vector3(0.45, 0, 0.9)  # facing the sea / sunset

@onready var track: Node3D = $Desert
@onready var camera: Camera3D = $MenuCamera

var _car: VehicleBody3D
var _cam_base := Transform3D()
var _cam_target := Transform3D()
var _cam_blend := 0.0          # 0 = title framing, 1 = map select framing
var _time := 0.0

var _title: Label
var _play: Control
var _maps: Control
var _back: Control
var _in_select := false
var _tween: Tween


func _ready() -> void:
	Game.state = Game.State.MENU
	_park_car()
	camera.make_current()
	_build_ui()
	_intro()

	var idle := AudioStreamPlayer.new()
	var stream: AudioStreamMP3 = load(IDLE_SOUND).duplicate()
	stream.loop = true
	stream.loop_offset = 0.5
	idle.stream = stream
	idle.bus = "SFX"
	idle.volume_db = -16.0
	add_child(idle)
	idle.play(0.5)


func _park_car() -> void:
	_car = track.get_node("Car/Car")
	_car.freeze = true
	var i := CAR_SAMPLE
	var p: Vector3 = track.samples[i]
	var right: Vector3 = track.tangents[i].cross(Vector3.UP).normalized()
	var heading := CAR_HEADING.normalized()
	var pos := p + right * 2.0 + Vector3.UP * 0.62
	_car.global_transform = Transform3D(Basis.looking_at(-heading, Vector3.UP), pos)

	# Rear three-quarter view, car on the left third of the screen
	var car_right := heading.cross(Vector3.UP).normalized()
	var title_pos := pos - heading * 5.2 - car_right * 2.8 + Vector3.UP * 1.3
	var title_look := pos + heading * 12.0 + car_right * 11.0 + Vector3.UP * 1.2
	_cam_base = Transform3D(Basis.looking_at(title_look - title_pos, Vector3.UP), title_pos)
	var select_pos := pos - heading * 8.0 - car_right * 4.5 + Vector3.UP * 2.4
	var select_look := pos + heading * 11.0 + car_right * 13.0 + Vector3.UP * 0.8
	_cam_target = Transform3D(Basis.looking_at(select_look - select_pos, Vector3.UP), select_pos)


func _process(delta: float) -> void:
	_time += delta
	var t := _cam_base.interpolate_with(_cam_target, _cam_blend)
	# very slow breathing drift so the shot feels alive
	t.origin += t.basis.x * sin(_time * 0.17) * 0.35 + Vector3.UP * sin(_time * 0.23) * 0.12
	camera.global_transform = t


func _unhandled_input(event: InputEvent) -> void:
	if _in_select and event.is_action_pressed("ui_cancel"):
		_show_title()


# ---------- UI ----------

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 10
	add_child(layer)
	var panel := Control.new()
	panel.anchor_left = 0.5
	panel.anchor_right = 1.0
	panel.anchor_bottom = 1.0
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(panel)

	_title = Label.new()
	_title.text = "aster"
	_title.label_settings = UIStyle.label(64, UIStyle.WHITE, 0.0, 200, 10)
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_title.offset_top = 118
	panel.add_child(_title)

	var play := NeonButton.new()
	play.text = "play"
	play.text_size = 20
	play.pressed.connect(_show_select)
	_play = _centered(panel, play, 200)

	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 14)
	for m in Game.MAPS:
		var b := NeonButton.new()
		b.text = m.name.to_lower()
		b.text_size = 18
		b.pressed.connect(Game.play_map.bind(m.scene))
		list.add_child(b)
	_maps = _centered(panel, list, 120)

	var back := NeonButton.new()
	back.text = "back"
	back.text_size = 11
	back.rest_alpha = 0.4
	back.pressed.connect(_show_title)
	_back = _centered(panel, back, 312)

	for c in [_maps, _back]:
		c.modulate.a = 0.0
		c.visible = false


func _centered(parent: Control, child: Control, top: float) -> Control:
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_TOP_WIDE)
	center.offset_top = top
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(child)
	parent.add_child(center)
	return center


func _intro() -> void:
	_title.modulate.a = 0.0
	_play.modulate.a = 0.0
	_title.offset_top += 10
	var t := create_tween().set_parallel()
	t.tween_property(_title, "modulate:a", 1.0, 1.2).set_delay(0.4)
	t.tween_property(_title, "offset_top", _title.offset_top - 10, 1.4).set_delay(0.4).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	t.tween_property(_play, "modulate:a", 1.0, 0.8).set_delay(1.3)
	t.chain().tween_callback(_play.get_child(0).grab_focus)


func _show_select() -> void:
	_in_select = true
	_maps.visible = true
	_back.visible = true
	_animate(true)
	_maps.get_child(0).get_child(0).grab_focus()


func _show_title() -> void:
	_in_select = false
	_animate(false)
	_play.get_child(0).grab_focus()


func _animate(to_select: bool) -> void:
	if _tween:
		_tween.kill()
	var s := 1.0 if to_select else 0.0
	_tween = create_tween().set_parallel().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_tween.tween_property(self, "_cam_blend", s, 1.2)
	_tween.tween_property(_title, "offset_top", lerpf(118, 28, s), 0.7)
	_tween.tween_property(_title.label_settings, "font_size", int(lerpf(64, 36, s)), 0.7)
	_tween.tween_property(_play, "modulate:a", 1.0 - s, 0.35)
	_tween.tween_property(_maps, "modulate:a", s, 0.5).set_delay(0.25 * s)
	_tween.tween_property(_maps, "offset_left", 0.0 if to_select else 30.0, 0.6).from(30.0 if to_select else 0.0).set_delay(0.2 * s)
	_tween.tween_property(_back, "modulate:a", s, 0.5).set_delay(0.4 * s)
	_play.visible = true
	_tween.chain().tween_callback(func():
		_play.visible = not to_select
		_maps.visible = to_select
		_back.visible = to_select)
