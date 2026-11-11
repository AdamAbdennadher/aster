extends CanvasLayer
## In-game speedometer (bottom center: km/h above a thin line that fills up in white) and lap chrono (top right).

const GAUGE_MAX_KMH := 220.0
const GAUGE_WIDTH := 150.0
const BOOST_WIDTH := 90.0
const BOOST_COLOR := Color(1.0, 0.82, 0.3)

var _speed_box: Control
var _speed_label: Label
var _gauge_fill: ColorRect

var _boost_box: VBoxContainer
var _boost_label: Label
var _boost_fill: ColorRect

var _chrono_box: VBoxContainer
var _time_label: Label
var _info_label: Label
var _result_label: Label
var _result_until := 0.0


func _ready() -> void:
	layer = 40
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_speedometer()
	_build_boost()
	_build_chrono()
	visible = Game.state == Game.State.PLAYING
	Game.state_changed.connect(func(s): visible = s == Game.State.PLAYING)
	Game.lap_completed.connect(_on_lap)
	Game.race_reset.connect(func(): _result_until = 0.0)


func _build_speedometer() -> void:
	_speed_box = VBoxContainer.new()
	_speed_box.anchor_left = 0.5
	_speed_box.anchor_right = 0.5
	_speed_box.anchor_top = 1.0
	_speed_box.anchor_bottom = 1.0
	_speed_box.offset_left = -GAUGE_WIDTH * 0.5
	_speed_box.offset_right = GAUGE_WIDTH * 0.5
	_speed_box.offset_top = -44
	_speed_box.offset_bottom = -14
	_speed_box.alignment = BoxContainer.ALIGNMENT_END
	_speed_box.add_theme_constant_override("separation", 3)
	_speed_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_speed_box)

	var number_row := HBoxContainer.new()
	number_row.alignment = BoxContainer.ALIGNMENT_CENTER
	number_row.add_theme_constant_override("separation", 4)
	_speed_box.add_child(number_row)
	_speed_label = Label.new()
	_speed_label.label_settings = UIStyle.label(18, UIStyle.WHITE, 0.0, 200, 1)
	number_row.add_child(_speed_label)
	var unit := Label.new()
	unit.text = "km/h"
	unit.label_settings = UIStyle.label(8, UIStyle.DIM, 0.0, 400, 1)
	unit.size_flags_vertical = Control.SIZE_SHRINK_END
	number_row.add_child(unit)

	# the line: dim track, white fill growing from the left
	var track := ColorRect.new()
	track.color = Color(UIStyle.WHITE, 0.2)
	track.custom_minimum_size = Vector2(GAUGE_WIDTH, 1)
	_speed_box.add_child(track)
	_gauge_fill = ColorRect.new()
	_gauge_fill.color = UIStyle.WHITE
	_gauge_fill.size = Vector2(0, 1)
	track.add_child(_gauge_fill)


# Boost gauge, bottom right: a small label above a thin yellow line that fills while drifting
func _build_boost() -> void:
	_boost_box = VBoxContainer.new()
	_boost_box.anchor_left = 1.0
	_boost_box.anchor_right = 1.0
	_boost_box.anchor_top = 1.0
	_boost_box.anchor_bottom = 1.0
	_boost_box.offset_left = -14 - BOOST_WIDTH
	_boost_box.offset_right = -14
	_boost_box.offset_top = -40
	_boost_box.offset_bottom = -14
	_boost_box.alignment = BoxContainer.ALIGNMENT_END
	_boost_box.add_theme_constant_override("separation", 3)
	_boost_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_boost_box)

	_boost_label = Label.new()
	_boost_label.text = "boost"
	_boost_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_boost_label.label_settings = UIStyle.label(8, UIStyle.DIM, 0.0, 400, 2)
	_boost_box.add_child(_boost_label)

	var track := ColorRect.new()
	track.color = Color(BOOST_COLOR, 0.2)
	track.custom_minimum_size = Vector2(BOOST_WIDTH, 2)
	_boost_box.add_child(track)
	_boost_fill = ColorRect.new()
	_boost_fill.color = BOOST_COLOR
	_boost_fill.size = Vector2(0, 2)
	track.add_child(_boost_fill)


func _build_chrono() -> void:
	_chrono_box = VBoxContainer.new()
	_chrono_box.anchor_left = 1.0
	_chrono_box.anchor_right = 1.0
	_chrono_box.offset_left = -170
	_chrono_box.offset_right = -14
	_chrono_box.offset_top = 10
	_chrono_box.alignment = BoxContainer.ALIGNMENT_BEGIN
	_chrono_box.add_theme_constant_override("separation", 1)
	_chrono_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_chrono_box)

	_time_label = Label.new()
	_time_label.label_settings = UIStyle.label(20, UIStyle.WHITE, 0.0, 200, 1)
	_time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_chrono_box.add_child(_time_label)
	_result_label = Label.new()
	_result_label.label_settings = UIStyle.label(9, UIStyle.WHITE, 0.0, 400, 2)
	_result_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_chrono_box.add_child(_result_label)
	_info_label = Label.new()
	_info_label.label_settings = UIStyle.label(8, UIStyle.DIM, 0.0, 400, 1)
	_info_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_chrono_box.add_child(_info_label)


func _process(_delta: float) -> void:
	if not visible:
		return
	var car := get_tree().get_first_node_in_group("player_car") as VehicleBody3D
	_speed_box.visible = car != null
	_boost_box.visible = car != null
	if car:
		var kmh: float = car.linear_velocity.length() * 3.6
		_speed_label.text = "%d" % roundi(kmh)
		_gauge_fill.size.x = GAUGE_WIDTH * clampf(kmh / GAUGE_MAX_KMH, 0.0, 1.0)
		var boost_car: Node = car   # untyped access: the boost fields come from car.gd, not VehicleBody3D
		_boost_fill.size.x = BOOST_WIDTH * float(boost_car.get("boost_meter"))
		# label lights up yellow when there is boost to use
		_boost_label.label_settings.font_color = BOOST_COLOR if boost_car.get("boost_ready") else UIStyle.DIM

	var race = Game.race
	_chrono_box.visible = is_instance_valid(race)
	if not _chrono_box.visible:
		return
	var now := Time.get_ticks_msec() / 1000.0
	var showing_result := now < _result_until
	if not showing_result:
		_time_label.text = Game.format_time(race.lap_time)
		_time_label.label_settings.font_color = UIStyle.WHITE if race.running else UIStyle.DIM
		_result_label.text = "" if race.running else "cross the line to start"
	var best: float = Game.best_time(Game.current_map)
	var best_text := "best  " + Game.format_time(best) if best < INF else "no record yet"
	_info_label.text = best_text + ("   ·   lap %d" % race.lap if race.running else "")


func _on_lap(time: float, rank: int, previous_best: float) -> void:
	_time_label.text = Game.format_time(time)
	_time_label.label_settings.font_color = UIStyle.WHITE
	if rank == 1:
		_result_label.text = "new record"
	elif previous_best < INF:
		_result_label.text = "+%.3f" % (time - previous_best)
	else:
		_result_label.text = ""
	_result_until = Time.get_ticks_msec() / 1000.0 + 3.0
