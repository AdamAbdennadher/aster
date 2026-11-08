extends Node
## Engine sound. Must be a direct child of the car (VehicleBody3D using car.gd).
## The sample is an engine start followed by a steady idle: the start plays once when the map begins,
## then the idle part loops and its pitch follows a simulated rpm with a 6-speed gearbox.

const SAMPLE := "res://sounds/motor/car-engine-335601.mp3"
const START_FROM := 1.3      # skip the silence at the beginning of the file
const LOOP_FROM := 5.5       # steady idle from here to the end of the file

@export var idle_rpm := 900.0
@export var redline_rpm := 7200.0
@export var gear_top_speeds := PackedFloat32Array([35, 60, 90, 125, 165, 220])  ## km/h at redline for each gear
@export var min_pitch := 0.9    ## pitch at idle
@export var max_pitch := 2.3    ## pitch at redline
@export var volume_on_throttle := -2.0
@export var volume_off_throttle := -9.0

@onready var car: VehicleBody3D = get_parent()

var rpm := 900.0
var gear := 1
var _start: AudioStreamPlayer
var _loop: AudioStreamPlayer
var _load := 0.0          # 0 = off throttle, 1 = full throttle, smoothed
var _running := false
var _lowpass: AudioEffectLowPassFilter


func _ready() -> void:
	var sample: AudioStreamMP3 = load(SAMPLE)
	_start = _make_player(sample)
	var looped: AudioStreamMP3 = sample.duplicate()
	looped.loop = true
	looped.loop_offset = LOOP_FROM
	_loop = _make_player(looped)
	var bus := AudioServer.get_bus_index("Engine")
	if bus != -1 and AudioServer.get_bus_effect_count(bus) > 0:
		_lowpass = AudioServer.get_bus_effect(bus, 0)
	Game.state_changed.connect(_on_game_state)
	_on_game_state(Game.state)


func _make_player(stream: AudioStream) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.stream = stream
	p.bus = "Engine"
	add_child(p)
	return p


func _on_game_state(state: Game.State) -> void:
	if state == Game.State.PLAYING and not _running:
		_start_engine()
	elif state == Game.State.MENU:
		_running = false
		_start.stop()
		_loop.stop()


# Starter + first revs from the file, then the idle loop fades in underneath
func _start_engine() -> void:
	_running = true
	_start.volume_db = 0.0
	_start.play(START_FROM)
	_loop.volume_db = -40.0
	_loop.play(LOOP_FROM)
	var t := create_tween()
	t.tween_interval(2.6)
	t.tween_property(_start, "volume_db", -40.0, 1.2)
	t.parallel().tween_property(_loop, "volume_db", volume_off_throttle, 1.2)
	t.tween_callback(_start.stop)


func _process(delta: float) -> void:
	if not _running:
		return
	var kmh: float = car.speed * 3.6
	var throttle: float = maxf(car.throttle_input, 0.0)
	_load = move_toward(_load, throttle, delta * 4.0)

	# Gear: lowest gear whose top speed is above the current speed (with a little hysteresis on downshift)
	var target_gear := gear_top_speeds.size()
	for i in gear_top_speeds.size():
		if kmh < gear_top_speeds[i] * 0.97:
			target_gear = i + 1
			break
	if target_gear < gear and kmh > gear_top_speeds[target_gear - 1] * 0.85:
		target_gear = gear
	gear = target_gear

	var low := 0.0 if gear == 1 else gear_top_speeds[gear - 2] * 0.6
	var ratio := clampf((kmh - low) / (gear_top_speeds[gear - 1] - low), 0.0, 1.0)
	var target_rpm := lerpf(idle_rpm, redline_rpm, ratio)
	# Wheelspin: revs climb when drifting or flooring it at low speed
	if car.is_drifting or (throttle > 0.5 and kmh < 15.0):
		target_rpm = maxf(target_rpm, lerpf(idle_rpm, redline_rpm, 0.55 + 0.35 * throttle))
	# Revs fall faster than they rise, and drop instantly on a gear change (rate is high)
	var rate := 9000.0 if target_rpm > rpm else 6000.0
	rpm = move_toward(rpm, target_rpm, rate * delta)

	var t := (rpm - idle_rpm) / (redline_rpm - idle_rpm)
	_loop.pitch_scale = lerpf(min_pitch, max_pitch, t)
	if not _start.playing:
		_loop.volume_db = lerpf(volume_off_throttle, volume_on_throttle, _load)
	if _lowpass:
		# muffled when lifting off, open when on the gas
		_lowpass.cutoff_hz = lerpf(1600.0, 9000.0, _load)
