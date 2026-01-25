extends CharacterBody3D

# --- Settings ---
const WALK_SPEED = 2.0
const RUN_SPEED = 6.0
const CROUCH_SPEED = 1.0
const JUMP_VELOCITY = 4.5
const MOUSE_SENSITIVITY = 0.006
const CAMERA_LAG_SPEED = 7.0

const ACCELERATION = 10.0
const DECELERATION = 4.0

# --- WEAPON INDICES (Matches your Transition Node Inputs) ---
const WEAPON_UNARMED = 0 # Input 0 in WeaponManager
const WEAPON_RIFLE = 1 # Input 1 in WeaponManager

# --- Nodes ---
@onready var camera_pivot: Node3D = $CameraPivot
@onready var camera: Camera3D = $CameraPivot/SpringArm3D/Camera3D
@onready var anim_tree = $AnimationTree
@onready var collision_shape = $CollisionShape3D
@onready var spring_arm: SpringArm3D = $CameraPivot/SpringArm3D
@onready var spine_ik: SkeletonIK3D = $soilder/Armature/Skeleton3D/SpineIK
@onready var head_target: Node3D = $soilder/Armature/Skeleton3D/HeadTarget

# --- NETWORK VARIABLES ---
@export var networked_velocity := Vector3.ZERO
@export var sync_cam_x_rot := 0.0
@export var current_weapon := WEAPON_UNARMED

@export var sync_is_grounded := true
@export var sync_is_jumping := false
@export var sync_is_crouching := false
@export var sync_is_sprinting := false

# --- ANIMATION SYNC VARIABLES (Add these to MultiplayerSynchronizer) ---
@export var sync_anim_blend_x := 0.0 # Blend position X (strafe left/right)
@export var sync_anim_blend_y := 0.0 # Blend position Y (forward/backward)
@export var sync_weapon_state := "unarmed" # Current weapon state name
@export var sync_is_moving := false # Is character moving?

# --- INPUT VARIABLES ---
@export var is_armed := false

var gravity = ProjectSettings.get_setting("physics/3d/default_gravity")
var default_height = 2.0
var crouch_height = 1.0

# --- JUMP SYSTEM VARIABLES ---
var jump_timer = 0.0 # Timer for delayed jump
var is_jump_delayed = false # Is jump waiting for animation windup?
var pending_jump_velocity = 0.0 # Stored jump velocity to apply later

# --- LATCHED JUMP STATE (Persistent Memory) ---
var is_run_jump_active = false # TRUE = Running jump, FALSE = Standing jump
# This variable is set when jump STARTS and persists until landing
# Prevents "memory loss" if player releases movement keys mid-air

func _enter_tree():
	set_multiplayer_authority(name.to_int())

func _ready():
	if is_multiplayer_authority():
		camera.current = true
		$CameraPivot/SpringArm3D.add_excluded_object(self.get_rid())
		camera_pivot.top_level = true
	else:
		set_physics_process(false)
		set_process_unhandled_input(false)

	anim_tree.active = true
	spine_ik.start()
	
	if collision_shape.shape is CapsuleShape3D:
		default_height = collision_shape.shape.height

func _process(delta):
	# --- 1. NETWORK SYNC ---
	if is_multiplayer_authority():
		# Server/Authority updates these values
		networked_velocity = velocity
		sync_cam_x_rot = spring_arm.rotation.x
		sync_is_sprinting = Input.is_action_pressed("sprint") and velocity.length() > 0.1
		sync_is_moving = velocity.length() > 0.1
		
		# Sync weapon state name for clients
		if current_weapon == WEAPON_UNARMED:
			sync_weapon_state = "unarmed"
		elif current_weapon == WEAPON_RIFLE:
			sync_weapon_state = "rifle"
	else:
		# Clients use synced values
		spring_arm.rotation.x = lerp_angle(spring_arm.rotation.x, sync_cam_x_rot, 15 * delta)
		
		# Apply synced weapon state on clients
		if sync_weapon_state == "unarmed":
			current_weapon = WEAPON_UNARMED
		elif sync_weapon_state == "rifle":
			current_weapon = WEAPON_RIFLE
	
	var world_velocity = networked_velocity

	# --- 2. WEAPON SWITCHING (Matches your Transition Node) ---
	# WeaponManager uses NAMED inputs: "unarmed" and "rifle"
	# NOT numeric indices 0 and 1
	
	# Use transition_request to switch between named inputs
	if current_weapon == WEAPON_UNARMED:
		anim_tree.set("parameters/WeaponManager/transition_request", "unarmed")
	elif current_weapon == WEAPON_RIFLE:
		anim_tree.set("parameters/WeaponManager/transition_request", "rifle")
	
	# --- 3. MOVEMENT & IK CONTROL ---
	var local_velocity = transform.basis.inverse() * world_velocity
	var current_speed = local_velocity.length()
	var is_moving = current_speed > 0.1
	
	# IK: Only aiming when Rifle is equipped (1) AND standing still
	var target_influence = 0.0
	if current_weapon == 1 and not is_moving:
		target_influence = 0.7
	spine_ik.interpolation = move_toward(spine_ik.interpolation, target_influence, 5.0 * delta)
	
	# --- 4. ANIMATION INTENSITY CALCULATION ---
	# Calculate the blend position based on actual speed relative to target speed
	var anim_intensity = 0.0
	
	if is_moving:
		# Calculate intensity based on current speed relative to the appropriate max speed
		if sync_is_crouching:
			# For crouch: normalize to crouch speed
			# At crouch speed (1.0), intensity should be 0.5 for proper walk animation
			anim_intensity = min(current_speed / CROUCH_SPEED, 1.0) * 0.5
		elif sync_is_sprinting or current_speed > 3.0:
			# For running: normalize to run speed
			# At run speed, intensity should be 1.0
			anim_intensity = min(current_speed / RUN_SPEED, 1.0) * 1.0
		else:
			# For walking: normalize to walk speed
			# At walk speed, intensity should be 0.5
			anim_intensity = min(current_speed / WALK_SPEED, 1.0) * 0.5

	# Create the smooth vector
	var move_direction = local_velocity.normalized()
	# Flip Z because Godot forward is negative
	var target_blend_vector = Vector2(move_direction.x, -move_direction.z) * anim_intensity
	var lerp_speed = 8.0 * delta
	
	# Sync blend position for clients
	if is_multiplayer_authority():
		sync_anim_blend_x = target_blend_vector.x
		sync_anim_blend_y = target_blend_vector.y
	else:
		# Clients use synced blend position
		target_blend_vector = Vector2(sync_anim_blend_x, sync_anim_blend_y)
		
		# DEBUG: Print client animation state
		if Engine.get_frames_drawn() % 60 == 0 and is_moving:
			print("CLIENT | Blend: (%.2f, %.2f) | Speed: %.2f | Weapon: %d" % [
				target_blend_vector.x, target_blend_vector.y, current_speed, current_weapon
			])
	
	# --- 5. UPDATE ANIMATIONS (The Paths) ---
	# CRITICAL: Only update the blend position for the CURRENTLY ACTIVE state
	# Updating inactive states can cause conflicts in the AnimationTree
	
	if current_weapon == WEAPON_UNARMED:
		# A. Unarmed - Check if crouching or standing
		if sync_is_crouching:
			# Unarmed Crouch - Use Crouch_Movement node
			var uc_pos = anim_tree.get("parameters/MainState/Crouch_Movement/blend_position")
			if uc_pos != null:
				anim_tree.set("parameters/MainState/Crouch_Movement/blend_position", uc_pos.lerp(target_blend_vector, lerp_speed))
			else:
				if Engine.get_frames_drawn() % 60 == 0:
					print("ERROR: Crouch_Movement path not found!")
		else:
			# Unarmed Stand - Use Movement node
			var u_pos = anim_tree.get("parameters/MainState/Movement/blend_position")
			if u_pos != null:
				anim_tree.set("parameters/MainState/Movement/blend_position", u_pos.lerp(target_blend_vector, lerp_speed))
			else:
				if Engine.get_frames_drawn() % 60 == 0:
					print("ERROR: Movement path not found!")
	
	elif current_weapon == WEAPON_RIFLE:
		# B. Rifle - Check if crouching or standing
		if sync_is_crouching:
			# C. Rifle Crouch
			var c_pos = anim_tree.get("parameters/Rifle_Movement/Rifle_Crouch/blend_position")
			if c_pos != null:
				anim_tree.set("parameters/Rifle_Movement/Rifle_Crouch/blend_position", c_pos.lerp(target_blend_vector, lerp_speed))
		else:
			# B. Rifle Stand
			var r_pos = anim_tree.get("parameters/Rifle_Movement/Rifle_Stand/blend_position")
			if r_pos != null:
				anim_tree.set("parameters/Rifle_Movement/Rifle_Stand/blend_position", r_pos.lerp(target_blend_vector, lerp_speed))
	
	# --- 6. JUMP & MOVEMENT CONDITIONS ---
	# Calculate movement state for jump branching
	# Use INPUT state, not velocity, to avoid residual velocity triggering wrong jump
	var input_dir = Input.get_vector("left", "right", "forward", "backward")
	var is_moving_input = input_dir.length() > 0.1
	
	# FALLING / JUMPING
	# Note: We check !grounded AND !jumping to detect falling off a ledge
	var is_falling = (not sync_is_grounded and not sync_is_jumping)
	
	# LATCHED JUMP STATE SYSTEM
	# Detects RISING EDGE of sync_is_jumping (false -> true transition)
	# and latches the jump type for the entire duration of the jump
	
	# Track previous jump state to detect rising edge
	var was_jumping_prev = get_meta("was_jumping_prev", false)
	var jump_rising_edge = sync_is_jumping and not was_jumping_prev
	set_meta("was_jumping_prev", sync_is_jumping)
	
	# When jump STARTS (rising edge), latch the jump type
	if jump_rising_edge:
		# Determine if this is a running or standing jump
		# Use input for local player, velocity for remote players
		if is_multiplayer_authority():
			is_run_jump_active = is_moving_input
		else:
			# For remote players, use synced movement state
			is_run_jump_active = sync_is_moving
		
		print("JUMP STARTED | Run Jump: %s | Moving Input: %s" % [is_run_jump_active, is_moving_input])
	
	# Reset latched state when landing
	if sync_is_grounded and not sync_is_jumping:
		is_run_jump_active = false
	
	# PERSISTENT JUMP CONDITIONS (Not one-frame triggers!)
	# These stay TRUE for the entire duration of the jump
	var perform_stand_jump = sync_is_jumping and not is_run_jump_active
	var perform_run_jump = sync_is_jumping and is_run_jump_active
	
	
	# Apply to MainState (Unarmed)
	anim_tree.set("parameters/MainState/conditions/is_falling", is_falling)
	anim_tree.set("parameters/MainState/conditions/is_grounded", sync_is_grounded)
	anim_tree.set("parameters/MainState/conditions/is_crouching", sync_is_crouching)
	anim_tree.set("parameters/MainState/conditions/is_standing", not sync_is_crouching)
	
	# MainState jump conditions (if your unarmed state has jump animations)
	# Use PERSISTENT state (sync_is_jumping), not one-frame trigger
	if current_weapon == WEAPON_UNARMED:
		anim_tree.set("parameters/MainState/conditions/is_jumping", sync_is_jumping)
	else:
		anim_tree.set("parameters/MainState/conditions/is_jumping", false)
	
	# Apply to Rifle_Movement (Armed)
	# Crouch conditions
	anim_tree.set("parameters/Rifle_Movement/conditions/is_crouching", sync_is_crouching)
	anim_tree.set("parameters/Rifle_Movement/conditions/is_standing", not sync_is_crouching)
	
	# Jump conditions - MUST match transition condition names (not node names!)
	# Rifle_Stand -> stand_jump node uses condition: jump_stand
	# Rifle_Stand -> jump_start node uses condition: jump_run
	# Only set when rifle is equipped
	if current_weapon == WEAPON_RIFLE:
		anim_tree.set("parameters/Rifle_Movement/conditions/jump_stand", perform_stand_jump)
		anim_tree.set("parameters/Rifle_Movement/conditions/jump_run", perform_run_jump)
	else:
		# Reset rifle jump conditions when unarmed
		anim_tree.set("parameters/Rifle_Movement/conditions/jump_stand", false)
		anim_tree.set("parameters/Rifle_Movement/conditions/jump_run", false)
	
	anim_tree.set("parameters/Rifle_Movement/conditions/is_grounded", sync_is_grounded)
	
	# Falling condition
	anim_tree.set("parameters/Rifle_Movement/conditions/is_falling", is_falling)


func _unhandled_input(event):
	if not is_multiplayer_authority(): return
	
	if event is InputEventMouseMotion:
		rotate_y(-event.relative.x * MOUSE_SENSITIVITY)
		spring_arm.rotate_x(-event.relative.y * MOUSE_SENSITIVITY)
		spring_arm.rotation.x = clamp(spring_arm.rotation.x, deg_to_rad(-90), deg_to_rad(90))
		
	# --- INPUT: SWITCH WEAPONS ---
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_1:
			current_weapon = WEAPON_UNARMED # 0
			print("Switching to Unarmed (current_weapon = %d)" % current_weapon)
		elif event.keycode == KEY_2:
			current_weapon = WEAPON_RIFLE # 1
			print("Switching to Rifle (current_weapon = %d)" % current_weapon)
		else:
			# Debug: Print what key was pressed
			if event.keycode in [KEY_1, KEY_2]:
				print("Key detected but not switching: keycode = %d" % event.keycode)

func _physics_process(delta):
	# --- GRAVITY ---
	if not is_on_floor():
		velocity.y -= gravity * delta
		sync_is_grounded = false
	else:
		sync_is_grounded = true
		sync_is_jumping = false

	# --- JUMP ---
	# Handle jump input and delayed jump execution
	if Input.is_action_just_pressed("jump") and is_on_floor() and not sync_is_crouching and not is_jump_delayed:
		# Check if player is moving to determine jump type
		var input_dir_check = Input.get_vector("left", "right", "forward", "backward")
		var is_moving_check = input_dir_check.length() > 0.1
		
		sync_is_jumping = true
		sync_is_grounded = false
		
		# CRITICAL: Only delay for RIFLE stand jumps, not unarmed
		if current_weapon == WEAPON_RIFLE and not is_moving_check:
			# Rifle standing jump - delay 0.5s for animation windup
			is_jump_delayed = true
			jump_timer = 0.5 # 0.5 second delay
			pending_jump_velocity = JUMP_VELOCITY
		else:
			# All other jumps (unarmed, rifle running) - apply velocity immediately
			velocity.y = JUMP_VELOCITY
			is_jump_delayed = false
	
	# Handle delayed jump execution
	if is_jump_delayed:
		jump_timer -= delta
		if jump_timer <= 0.0:
			velocity.y = pending_jump_velocity
			is_jump_delayed = false
			jump_timer = 0.0

	# --- CROUCH TOGGLE ---
	if Input.is_action_just_pressed("crouch") and is_on_floor():
		sync_is_crouching = not sync_is_crouching

	# --- CAMERA LAG SYSTEM ---
	var target_pos = head_target.global_position
	camera_pivot.global_position = camera_pivot.global_position.lerp(target_pos, CAMERA_LAG_SPEED * delta)
	camera_pivot.rotation.y = rotation.y

	# --- MOVEMENT CALCULATION ---
	var input_dir = Input.get_vector("left", "right", "forward", "backward")
	var target_speed = WALK_SPEED
	
	if sync_is_crouching:
		target_speed = CROUCH_SPEED
	elif Input.is_action_pressed("sprint") and input_dir.y < 0:
		target_speed = RUN_SPEED

	var direction = (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()

	if direction:
		velocity.x = move_toward(velocity.x, direction.x * target_speed, ACCELERATION * delta)
		velocity.z = move_toward(velocity.z, direction.z * target_speed, ACCELERATION * delta)
	else:
		velocity.x = move_toward(velocity.x, 0, DECELERATION * delta)
		velocity.z = move_toward(velocity.z, 0, DECELERATION * delta)

	move_and_slide()
