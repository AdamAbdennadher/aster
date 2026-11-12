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

@export_group("Power drift")
## Kicking the rear out without the handbrake: full lock with throttle held for kick_hold_time, or a quick
## steering flick (full lock one way then the other) which kicks right away and harder
@export var kick_min_speed_kmh := 40.0
@export var kick_min_speed_coast_kmh := 70.0   ## same without throttle: above this speed the rear can still be kicked out and keeps sliding
@export var coast_drift_looseness := 0.7       ## how loose the rear gets in a drift without throttle (0 = full grip, 1 = like full throttle)
@export var kick_steer := 0.85
@export var kick_hold_time := 0.18
@export var kick_yaw := 1.3                ## rad/s added to the rotation when the rear kicks out
@export var flick_yaw := 1.9
@export var flick_window := 0.35            ## seconds between the two steering locks for it to count as a flick
@export var kick_duration := 0.25         ## the extra rotation is spread over this time, and the car stays in drift mode meanwhile

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
@export var bump_stop_max := 50.0          ## cap on the bump stop push (m/s2 per wheel): an uncapped push on landings can roll the car over

@export_group("Air")
@export var air_roll_damping := 4.0      ## in the air, how fast sideways rotation dies down (avoids barrel rolls off jumps)
@export var air_roll_leveling := 3.0     ## in the air, how strongly the car rolls back to level

@export_group("Boost")
@export var boost_fill_time := 4.5        ## seconds of a good drift to fill the gauge
@export var boost_duration := 2.5         ## seconds of boost from a full gauge
@export var boost_accel := 14.0           ## m/s2 pushed forward while boosting
@export var boost_max_speed_kmh := 230.0  ## no more push above this speed

@export_group("Lights")
@export var drift_light_boost := 4.0     ## red rear light brightness while the handbrake is held (1 = normal)
@export var drift_light_speed := 14.0    ## how fast it brightens and dims back

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
var boost_meter := 0.0         # 0..1, filled by drifting
var boost_ready := false       # true while there is boost in the gauge
var is_boosting := false
var last_speed := 0.0
var throttle_input := 0.0
var _flipped_time := 0.0
var _follow_yaw := 0.0
var _cam_yaw := 0.0          # player offset around the car (mouse / right stick)
var _cam_pitch := 0.0
var _cam_idle := 0.0
var _steer_smooth := 0.0    # steering input eased in over time, so taps and holds stay gradual
var _wheel_visuals: Array = []   # [wheel, mesh, mesh rest transform]
var _hit_cooldown := 0.0   # seconds left during which the arcade assists leave the physics alone after hitting something
var _hold_still := true   # parked after the spawn or a reset until the player touches a control: no rolling down slopes
var _tail_light: StandardMaterial3D
var _tail_base_energy := 1.0
var _kick_hold := 0.0
var _kick_left := 0.0       # seconds left in the current kick
var _kick_rate := 0.0       # signed rad/s added per second of kick
var _last_lock_side := 0.0
var _last_lock_time := -10.0


func _ready() -> void:
	add_to_group("player_car")
	contact_monitor = true
	max_contacts_reported = 6
	add_child(load("res://scripts/car/boost_fx.gd").new())
	_tail_light = load("res://models/car/materials/Matériau.003.tres")
	if _tail_light:
		_tail_base_energy = _tail_light.emission_energy_multiplier
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
	if handbrake or _kick_left > 0.0:
		_steer_smooth = steer_input
	else:
		# a bit quicker in a drift so corrections and countersteer come in time, still not all-or-nothing
		_steer_smooth = move_toward(_steer_smooth, steer_input, steer_smoothing * (1.6 if is_drifting else 1.0) * delta)

	if _hold_still:
		if playing and (absf(throttle) > 0.05 or absf(steer_input) > 0.05 or handbrake or Input.is_action_pressed("boost")):
			_hold_still = false
		else:
			apply_central_impulse(-Vector3(linear_velocity.x, 0.0, linear_velocity.z) * mass)
			apply_torque_impulse(get_inverse_inertia_tensor().inverse() * (-Vector3.UP * angular_velocity.y))
	update_slip()
	_update_hit_cooldown(delta)

	var sliding: bool = speed > drift_min_speed and absf(slip_angle) > deg_to_rad(drift_min_angle_deg)
	# two thresholds: entering a drift needs a real slide, staying in it only a small one
	var still_sliding: bool = speed > drift_min_speed and absf(slip_angle) > deg_to_rad(drift_keep_angle_deg)
	var kicked := _power_drift_kick(steer_input, throttle, delta)
	if _hit_cooldown > 0.0:
		# the slide right after a crash comes from the impact: it must not switch the car into drift mode
		is_drifting = handbrake or (is_drifting and still_sliding)
	else:
		is_drifting = handbrake or kicked or ((throttle > 0.1 or speed * 3.6 > kick_min_speed_coast_kmh) and (sliding or (is_drifting and still_sliding)))

	var target_grip := 1.0
	if handbrake:
		target_grip = handbrake_grip
	elif is_drifting:
		var coasting := coast_drift_looseness if speed * 3.6 > kick_min_speed_coast_kmh else 0.0
		target_grip = lerpf(1.0, drift_grip, maxf(throttle, coasting))
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

	# right after a hit the assists stay off, so every crash is resolved by the physics alone (same speed loss,
	# same bounce) instead of being partly undone by the drift speed keeping or the trajectory correction
	if _hit_cooldown <= 0.0:
		if is_drifting and is_on_ground():
			drift_assist(_steer_smooth, handbrake, delta)
		else:
			_turn_assist(delta)
	last_speed = speed

	_apply_bump_stops()
	if not is_on_ground():
		_stabilize_in_air(delta)
	_update_boost(delta, playing)
	if playing:
		_check_flipped(delta)
	update_camera(delta)
	_update_wheel_visuals()


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


# Drifting fills the gauge (faster with a wider slide). Holding boost pushes the car forward as long as
# there is something in the gauge, in any situation (straight line, drift, in the air).
func _update_boost(delta: float, playing: bool) -> void:
	if is_drifting and is_on_ground() and speed > drift_min_speed:
		var amount := clampf(absf(slip_angle) / deg_to_rad(25.0), 0.3, 1.0)
		boost_meter = minf(1.0, boost_meter + amount * delta / boost_fill_time)
	boost_ready = boost_meter > 0.0
	is_boosting = playing and boost_ready and Input.is_action_pressed("boost")
	if not is_boosting:
		return
	boost_meter = maxf(0.0, boost_meter - delta / boost_duration)
	if speed * 3.6 < boost_max_speed_kmh:
		apply_central_force(global_basis.z * mass * boost_accel)


func _power_drift_kick(steer_input: float, throttle: float, delta: float) -> bool:
	if _kick_left > 0.0:
		_kick_left -= delta
		apply_torque_impulse(get_inverse_inertia_tensor().inverse() * (Vector3.UP * _kick_rate * delta))
		return true
	var now := Time.get_ticks_msec() / 1000.0
	var lock_side := signf(steer_input) if absf(steer_input) > kick_steer else 0.0
	var flick := false
	if lock_side != 0.0:
		flick = _last_lock_side == -lock_side and now - _last_lock_time < flick_window
		if lock_side != _last_lock_side:
			_kick_hold = 0.0
		_last_lock_side = lock_side
		_last_lock_time = now
	var able := not is_drifting and _hit_cooldown <= 0.0 and is_on_ground() and lock_side != 0.0 and (throttle > 0.5 and speed * 3.6 > kick_min_speed_kmh or speed * 3.6 > kick_min_speed_coast_kmh)
	if not able:
		_kick_hold = 0.0
		return false
	_kick_hold += delta
	if not flick and _kick_hold < kick_hold_time:
		return false
	_kick_hold = 0.0
	_last_lock_side = 0.0
	_kick_left = kick_duration
	# aims at a rotation in the new direction rather than adding a fixed amount: after a flick the car is still
	# turning the other way, and a fixed push would only cancel that
	var need := lock_side * (flick_yaw if flick else kick_yaw) - angular_velocity.y
	if need * lock_side < 0.3:
		need = lock_side * 0.3
	_kick_rate = need / kick_duration
	return true


func _update_hit_cooldown(delta: float) -> void:
	_hit_cooldown = maxf(0.0, _hit_cooldown - delta)
	for body in get_colliding_bodies():
		if body.name != "Road" and body.name != "Terrain":
			_hit_cooldown = 0.35
			return


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
		var push := minf(bump_stop_strength * depth + bump_stop_damping * maxf(closing, 0.0), bump_stop_max)
		apply_force(up * push * mass, offset)


# Arcade air control: damp the roll (rotation around the car's length) and ease it back to level, so a
# slightly uneven take-off does not turn into a barrel roll. Pitch is left alone so jumps keep their arc.
func _stabilize_in_air(delta: float) -> void:
	var forward := global_basis.z
	var roll_rate := angular_velocity.dot(forward)
	# signed roll angle: how far the car's up vector leans sideways, measured around its forward axis
	var flat_up := (Vector3.UP - forward * Vector3.UP.dot(forward)).normalized()
	var roll_angle := global_basis.y.signed_angle_to(flat_up, forward)
	var wanted_rate := roll_angle * air_roll_leveling
	var change := (wanted_rate - roll_rate) * clampf(air_roll_damping * delta, 0.0, 1.0)
	apply_torque_impulse(get_inverse_inertia_tensor().inverse() * (forward * change))


# Godot's raycast suspension draws the wheel lower than its real contact, more so as the spring compresses,
# so wheels visibly sink into the road. Lift each wheel mesh back onto the ground, but never above its place in
# the model (visual only, physics unchanged).
func _process(delta: float) -> void:
	if _tail_light == null:
		return
	var held := Game.state == Game.State.PLAYING and Input.is_action_pressed("handbrake")
	var target := _tail_base_energy * (drift_light_boost if held else 1.0)
	_tail_light.emission_energy_multiplier = lerpf(_tail_light.emission_energy_multiplier, target, clampf(drift_light_speed * delta, 0.0, 1.0))


func _update_wheel_visuals() -> void:
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
	if _kick_left > 0.0:
		traction = 0.0   # let the rear swing out during a power drift kick
	flat_vel = flat_vel.rotated(up, clampf(angle_to_nose, -traction * delta, traction * delta))

	# only gives back the speed scrubbed by the sideways slide (a few m/s2), never a sudden loss
	if not handbrake and flat_vel.length() < last_speed and last_speed - flat_vel.length() < 0.25:
		flat_vel = flat_vel.normalized() * lerpf(flat_vel.length(), last_speed, drift_speed_keep)

	linear_velocity = Vector3(flat_vel.x, vel.y, flat_vel.z)
	# Store the corrected speed, otherwise next frame only compensates one frame of loss.
	speed = flat_vel.length()


func update_slip() -> void:
	var local_vel := global_basis.inverse() * linear_velocity
	local_vel.y = 0.0
	speed = local_vel.length()
	# only while rolling forward: rolling backward (even with the throttle already pressed to go forward again)
	# would read as a 180 deg slide and the drift code would spin the car on its own
	if speed > 1.0 and local_vel.z > 1.0:
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
	boost_meter = 0.0
	boost_ready = false
	is_boosting = false
	# Teleport in the physics server itself: only setting the node transform can get overwritten by
	# the physics state on the next step, and the car stays where it was
	var rid := get_rid()
	PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_TRANSFORM, spawn_transform)
	PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
	PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, Vector3.ZERO)
	global_transform = spawn_transform
	reset_interpolation_all()
	_hit_cooldown = 0.0
	_kick_left = 0.0
	_hold_still = true
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


# After a teleport: the body, wheels and wheel meshes must all forget their previous position, otherwise
# physics interpolation draws them sliding from where they were (a frozen car never catches up)
func reset_interpolation_all() -> void:
	reset_physics_interpolation()
	for node in find_children("*", "Node3D", true, false):
		(node as Node3D).reset_physics_interpolation()


func snap_camera() -> void:
	_follow_yaw = global_rotation.y
	_cam_yaw = 0.0
	_cam_pitch = 0.0
	camera_pivot.global_position = global_position
	camera_pivot.global_rotation = Vector3(0.0, _follow_yaw, 0.0)
	camera_pivot.reset_physics_interpolation()
