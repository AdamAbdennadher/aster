extends VehicleBody3D

const CAM_FOLLOW_SPEED = 20.0
const CAM_ROTATE_SPEED = 5.0

@export_group("Engine")
@export var engine_power := 300.0

@export_group("Steering")
@export var max_steer := 0.8              ## radians
@export var max_steer_at_speed := 0.35    ## radians
@export var max_turn_rate := 2.2          ## rad/s the car turns at full lock outside drifts, whatever its speed (keeps the turn steady)
@export var handling_ref_speed := 40.0     ## km/h: above this, turning and drifting calm down so high speed feels like this speed
@export var turn_speed_falloff := 0.5     ## how much turning calms down above handling_ref_speed: 0 = not at all, 1 = a lot (truck-like)
@export var drift_speed_falloff := 0.25    ## same for the drift rotation (the drift path keeps curving at any speed)
@export var steer_speed_ref := 30.0       ## m/s at which max_steer_at_speed is reached
@export var steer_time := 0.25            ## seconds for the wheels to go from straight to full lock, at any speed
@export var drift_steer_bonus := 0.35     ## extra steering angle while drifting
@export var countersteer_assist := 0.5
@export var turn_sharpness := 1.15        ## 1 = what the steering angle gives, higher = tighter turns (wheel angle unchanged)
@export var steer_smoothing := 5.0        ## how fast the steering input builds up (keyboard is all-or-nothing): lower = more gradual

@export_group("Drift")
@export var handbrake_grip := 0.3         ## multiplier of the rear wheels' base friction
@export var drift_grip := 0.45            ## multiplier of the rear wheels' base friction
@export var handbrake_brake := 0.4
@export var grip_loss_speed := 10.0
@export var grip_recovery_speed := 1.5
@export var drift_min_angle_deg := 8.0    ## sliding this much with throttle on switches to drift mode (the handbrake always does)
@export var drift_keep_angle_deg := 3.0   ## once drifting, the drift goes on until the slide drops below this (so it does not cut out right after the handbrake)
@export var drift_min_speed := 5.0        ## m/s

@export_group("Drift assist")
@export var drift_yaw_rate := 2.0         ## rad/s at full steering lock
@export var drift_yaw_control := 6.0
@export var drift_traction := 0.8         ## rad/s at which velocity rotates toward the car's nose
@export var drift_speed_keep := 0.9       ## 0..1, share of the speed lost while sliding that is given back
@export var max_drift_angle_deg := 45.0
@export var countersteer_boost := 1.6      ## countersteering in a drift turns back this much faster, to catch the slide

@export_group("Camera")
@export var mouse_sensitivity := 0.003
@export var stick_camera_speed := 2.5      ## rad/s at full right stick
@export var camera_recenter_delay := 1.5  ## seconds without camera input before it swings back behind the car
@export var camera_pitch_min := -0.25
@export var camera_pitch_max := 0.6

@export_group("Wheels")
@export var wheel_model_height := -0.335   ## car-local height of the wheel centers in the model: wheels never go higher (no clipping into the body)
@export var bump_stop_margin := 0.015      ## the bump stop starts pushing this far below the wheel arch
@export var bump_stop_strength := 500.0
@export var bump_stop_damping := 20.0

@export_group("Game over")
@export var flip_tilt := 0.35             ## car up-vector dot world-up below this counts as flipped (~70 deg)
@export var flip_time := 2.0              ## seconds stuck flipped before game over

signal car_reset   # R pressed (or fell in the sea): the car is back at the spawn

@onready var camera_pivot: Node3D = $CameraPivot
@onready var camera_3d: Camera3D = $CameraPivot/Camera3D
@onready var rear_wheels: Array[VehicleWheel3D] = [$BL, $BR]

var spawn_transform: Transform3D
var rear_base_grip := 1.0
var rear_grip_factor := 1.0

var speed := 0.0
var slip_angle := 0.0          # radians, negative when the rear slides out to the right
var is_drifting := false
var last_speed := 0.0
var throttle_input := 0.0
var _flipped_time := 0.0
var _follow_yaw := 0.0
var _cam_yaw := 0.0          # player offset around the car (mouse / right stick)
var _cam_pitch := 0.0
var _cam_idle := 0.0
var _steer_smooth := 0.0    # steering input eased in over time, so taps and holds stay gradual
var _wheel_visuals: Array = []   # [wheel, mesh, mesh rest transform]


func _ready() -> void:
	add_to_group("player_car")
	Game.state_changed.connect(_on_game_state)
	_on_game_state(Game.state)
	spawn_transform = global_transform
	rear_base_grip = rear_wheels[0].wheel_friction_slip
	for wheel in [$FL, $FR, $BL, $BR]:
		for child in wheel.get_children():
			if child is MeshInstance3D:
				_wheel_visuals.append([wheel, child, child.transform])
	snap_camera()


func _physics_process(delta: float) -> void:
	var playing := Game.state == Game.State.PLAYING
	var throttle := Input.get_axis("brake", "accelerate") if playing else 0.0
	var steer_input := Input.get_axis("steer_right", "steer_left") if playing else 0.0
	var handbrake := Input.is_action_pressed("handbrake") if playing else false
	throttle_input = throttle
	# the handbrake flick stays instant (drift entry), everything else builds up gradually
	if handbrake:
		_steer_smooth = steer_input
	else:
		# a bit quicker in a drift so corrections and countersteer come in time, still not all-or-nothing
		_steer_smooth = move_toward(_steer_smooth, steer_input, steer_smoothing * (1.6 if is_drifting else 1.0) * delta)

	update_slip()

	var sliding: bool = speed > drift_min_speed and absf(slip_angle) > deg_to_rad(drift_min_angle_deg)
	# two thresholds: entering a drift needs a real slide, staying in it only a small one
	var still_sliding: bool = speed > drift_min_speed and absf(slip_angle) > deg_to_rad(drift_keep_angle_deg)
	is_drifting = handbrake or (throttle > 0.1 and (sliding or (is_drifting and still_sliding)))

	var target_grip := 1.0
	if handbrake:
		target_grip = handbrake_grip
	elif is_drifting:
		target_grip = lerpf(1.0, drift_grip, throttle)
	var rate := grip_loss_speed if target_grip < rear_grip_factor else grip_recovery_speed
	rear_grip_factor = move_toward(rear_grip_factor, target_grip, rate * delta)
	for wheel in rear_wheels:
		wheel.wheel_friction_slip = rear_base_grip * rear_grip_factor
		wheel.brake = handbrake_brake if handbrake else 0.0

	var steer_limit: float
	if is_drifting:
		steer_limit = lerpf(max_steer, max_steer_at_speed, clampf(speed / steer_speed_ref, 0.0, 1.0)) + drift_steer_bonus
	else:
		# wheel angle that gives max_turn_rate at this speed: the car does not turn sharper and sharper as it slows
		var wheelbase := absf($FL.position.z - $BL.position.z)
		steer_limit = minf(max_steer, atan(wheelbase * max_turn_rate * _speed_scale(turn_speed_falloff) / maxf(speed, 1.0)))
	var target_steer := _steer_smooth * steer_limit
	if sliding:
		target_steer += slip_angle * countersteer_assist
	target_steer = clampf(target_steer, -max_steer - drift_steer_bonus, max_steer + drift_steer_bonus)
	steering = move_toward(steering, target_steer, steer_limit / steer_time * delta)

	engine_force = throttle * engine_power

	if is_drifting and is_on_ground():
		drift_assist(_steer_smooth, handbrake, delta)
	else:
		_turn_assist(delta)
	last_speed = speed

	_apply_bump_stops()
	if playing:
		_check_flipped(delta)
	update_camera(delta)


# Upside down or on its side and not moving anymore for flip_time seconds: game over (R still saves you before)
func _check_flipped(delta: float) -> void:
	if global_basis.y.dot(Vector3.UP) < flip_tilt and linear_velocity.length() < 4.0:
		_flipped_time += delta
		if _flipped_time >= flip_time:
			Game.game_over()
	else:
		_flipped_time = 0.0


func _on_game_state(state: Game.State) -> void:
	if state == Game.State.PLAYING:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


# Bump stops: when a wheel gets close to the top of its arch (suspension fully compressed), push the body up
# at that corner, so the body can never come down over the wheels further than the room left in the model.
func _apply_bump_stops() -> void:
	var up := global_basis.y
	var inv := global_transform.affine_inverse()
	for v in _wheel_visuals:
		var wheel: VehicleWheel3D = v[0]
		if not wheel.is_in_contact():
			continue
		var center := wheel.get_contact_point() + up * wheel.wheel_radius
		var depth := (inv * center).y - (wheel_model_height - bump_stop_margin)
		if depth <= 0.0:
			continue
		var offset := center - global_position
		var closing := -(linear_velocity + angular_velocity.cross(offset)).dot(up)
		var push := bump_stop_strength * depth + bump_stop_damping * maxf(closing, 0.0)
		apply_force(up * push * mass, offset)


# Godot's raycast suspension draws the wheel lower than its real contact, more so as the spring compresses,
# so wheels visibly sink into the road. Lift each wheel mesh back onto the ground, but never above its place in
# the model (visual only, physics unchanged).
func _process(_delta: float) -> void:
	var up := global_basis.y
	for v in _wheel_visuals:
		var wheel: VehicleWheel3D = v[0]
		var mesh: MeshInstance3D = v[1]
		mesh.transform = v[2]
		if wheel.is_in_contact():
			var sink := wheel.wheel_radius - (wheel.global_position - wheel.get_contact_point()).dot(up)
			if sink > 0.0:
				mesh.global_position += up * minf(sink, wheel.wheel_radius)
		# never above the wheel arch of the model, even when the suspension is fully compressed
		var above := (global_transform.affine_inverse() * mesh.global_position).y - wheel_model_height
		if above > 0.0:
			mesh.global_position -= up * above


# Tighter turns without a bigger wheel angle: the car yaws turn_sharpness times faster than its steering angle
# would give with perfect grip (same ratio from the start of the turn, so the response stays predictable),
# and its trajectory follows the nose so it turns instead of sliding.
func _turn_assist(delta: float) -> void:
	if turn_sharpness <= 1.0 or speed < 2.0 or absf(steering) < 0.02 or not is_on_ground():
		return
	var up := Vector3.UP
	var forward_speed := (global_basis.inverse() * linear_velocity).z
	var wheelbase := absf($FL.position.z - $BL.position.z)
	var natural := forward_speed * tan(steering) / wheelbase
	# capped: right after a drift the wheels are still turned a lot, which would otherwise ask for a violent yaw
	var cap := max_turn_rate * _speed_scale(turn_speed_falloff) * turn_sharpness
	var desired := clampf(natural * turn_sharpness, -cap, cap)
	var yaw := angular_velocity.dot(up)
	var yaw_change := up * (desired - yaw) * clampf(6.0 * delta, 0.0, 1.0)
	# impulses add to the physics step instead of overwriting it (setting the velocities would cancel the engine)
	apply_torque_impulse(get_inverse_inertia_tensor().inverse() * yaw_change)

	var vel := linear_velocity
	var flat := Vector3(vel.x, 0.0, vel.z)
	var nose := Vector3(global_basis.z.x, 0.0, global_basis.z.z).normalized() * signf(forward_speed)
	var max_turn := (absf(desired) + 0.5) * delta
	var turned := flat.rotated(up, clampf(flat.signed_angle_to(nose, up), -max_turn, max_turn))
	apply_central_impulse((turned - flat) * mass)


# 1 below handling_ref_speed, then shrinks with speed (falloff 1 = inversely proportional to speed)
func _speed_scale(falloff: float) -> float:
	var ref := handling_ref_speed / 3.6
	return pow(minf(1.0, ref / maxf(speed, 0.1)), falloff)


func is_on_ground() -> bool:
	for wheel in [$BL, $BR, $FL, $FR]:
		if wheel.is_in_contact():
			return true
	return false


func drift_assist(steer_input: float, handbrake: bool, delta: float) -> void:
	var up := Vector3.UP
	var yaw_rate := angular_velocity.dot(up)
	var max_angle := deg_to_rad(max_drift_angle_deg)

	var desired_yaw := steer_input * drift_yaw_rate * clampf(speed / 10.0, 0.0, 1.0) * _speed_scale(drift_speed_falloff)
	# Yawing against the sign of slip_angle widens the drift: past max angle, block that and pull back.
	var opening := -signf(slip_angle) * desired_yaw > 0.0
	if absf(slip_angle) > max_angle and opening:
		desired_yaw = signf(slip_angle) * (absf(slip_angle) - max_angle) * 6.0
	# countersteering = already sliding and steering to reduce the slide: turn back faster, pull the trajectory onto the nose sooner
	var countersteering := absf(slip_angle) > deg_to_rad(4.0) and signf(slip_angle) * desired_yaw > 0.0
	if countersteering and absf(slip_angle) <= max_angle:
		desired_yaw *= countersteer_boost
	angular_velocity += up * (desired_yaw - yaw_rate) * clampf(drift_yaw_control * delta, 0.0, 1.0)

	var vel := linear_velocity
	var flat_vel := Vector3(vel.x, 0.0, vel.z)
	if flat_vel.length() < 0.5:
		return
	var forward := Vector3(global_basis.z.x, 0.0, global_basis.z.z).normalized()
	var angle_to_nose := flat_vel.signed_angle_to(forward, up)
	var traction := drift_traction * (countersteer_boost if countersteering else 1.0)
	flat_vel = flat_vel.rotated(up, clampf(angle_to_nose, -traction * delta, traction * delta))

	if not handbrake and flat_vel.length() < last_speed:
		flat_vel = flat_vel.normalized() * lerpf(flat_vel.length(), last_speed, drift_speed_keep)

	linear_velocity = Vector3(flat_vel.x, vel.y, flat_vel.z)
	# Store the corrected speed, otherwise next frame only compensates one frame of loss.
	speed = flat_vel.length()


func update_slip() -> void:
	var local_vel := global_basis.inverse() * linear_velocity
	local_vel.y = 0.0
	speed = local_vel.length()
	var reversing := local_vel.z < 0.0 and Input.get_axis("brake", "accelerate") < 0.0
	if speed > 1.0 and not reversing:
		slip_angle = atan2(local_vel.x, local_vel.z)
	else:
		slip_angle = 0.0


func _unhandled_input(event: InputEvent) -> void:
	if Game.state != Game.State.PLAYING:
		return
	if event.is_action_pressed("reset_car"):
		reset_car()
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_cam_yaw -= event.relative.x * mouse_sensitivity
		_cam_pitch += event.relative.y * mouse_sensitivity
		_cam_idle = 0.0


func reset_car() -> void:
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	engine_force = 0.0
	steering = 0.0
	rear_grip_factor = 1.0
	_steer_smooth = 0.0
	_flipped_time = 0.0
	global_transform = spawn_transform
	snap_camera()
	car_reset.emit()


func update_camera(delta: float) -> void:
	camera_pivot.global_position = camera_pivot.global_position.lerp(global_position, delta * CAM_FOLLOW_SPEED)
	_follow_yaw = lerp_angle(_follow_yaw, global_rotation.y, delta * CAM_ROTATE_SPEED)

	var stick := Vector2.ZERO
	if Game.state == Game.State.PLAYING:
		stick = Input.get_vector("camera_left", "camera_right", "camera_up", "camera_down")
	if stick.length() > 0.05:
		_cam_yaw -= stick.x * stick_camera_speed * delta
		_cam_pitch += stick.y * stick_camera_speed * delta
		_cam_idle = 0.0
	else:
		_cam_idle += delta
	if _cam_idle > camera_recenter_delay:
		_cam_yaw = lerp_angle(_cam_yaw, 0.0, delta * 2.0)
		_cam_pitch = lerpf(_cam_pitch, 0.0, delta * 2.0)
	_cam_pitch = clampf(_cam_pitch, camera_pitch_min, camera_pitch_max)
	camera_pivot.global_rotation = Vector3(_cam_pitch, _follow_yaw + _cam_yaw, 0.0)


func snap_camera() -> void:
	_follow_yaw = global_rotation.y
	_cam_yaw = 0.0
	_cam_pitch = 0.0
	camera_pivot.global_position = global_position
	camera_pivot.global_rotation = Vector3(0.0, _follow_yaw, 0.0)
