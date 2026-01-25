extends CharacterBody3D

# --- Settings ---
const WALK_SPEED = 2.0
const RUN_SPEED = 6.0
const CROUCH_SPEED = 1.0
const JUMP_VELOCITY = 4.5
const MOUSE_SENSITIVITY = 0.003
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

# --- INPUT VARIABLES ---
@export var is_armed := false

var gravity = ProjectSettings.get_setting("physics/3d/default_gravity")
var default_height = 2.0
var crouch_height = 1.0

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
		networked_velocity = velocity
		sync_cam_x_rot = spring_arm.rotation.x
		sync_is_sprinting = Input.is_action_pressed("sprint") and velocity.length() > 0.1
	else:
		spring_arm.rotation.x = lerp_angle(spring_arm.rotation.x, sync_cam_x_rot, 15 * delta)
	
	var world_velocity = networked_velocity

	# --- 2. WEAPON SWITCHING (Matches your Transition Node) ---
	# 0 = Unarmed, 1 = Rifle
	anim_tree.set("parameters/WeaponManager/current", current_weapon)
	
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
	
	# DEBUG: Print blend position info (Remove this after testing)
	if is_moving and Engine.get_frames_drawn() % 30 == 0: # Print every 30 frames to avoid spam
		print("Speed: %.2f | Intensity: %.2f | Crouch: %s | Weapon: %d | Target: %s" % [
			current_speed, anim_intensity, sync_is_crouching, current_weapon, target_blend_vector
		])
	
	# --- 6. CRITICAL CONDITIONS (Falling & Crouching) ---
	# This section was missing in the previous step, causing your bugs.
	
	# FALLING / JUMPING
	# Note: We check !grounded AND !jumping to detect falling off a ledge
	var is_falling = (not sync_is_grounded and not sync_is_jumping)
	
	# Apply to MainState (Unarmed)
	anim_tree.set("parameters/MainState/conditions/is_falling", is_falling)
	anim_tree.set("parameters/MainState/conditions/is_grounded", sync_is_grounded)
	anim_tree.set("parameters/MainState/conditions/is_jumping", sync_is_jumping)
	anim_tree.set("parameters/MainState/conditions/is_crouching", sync_is_crouching)
	anim_tree.set("parameters/MainState/conditions/is_standing", not sync_is_crouching)
	
	# Apply to Rifle_Movement (Armed)
	# Check if your Rifle state machine has these conditions. If not, this won't hurt.
	anim_tree.set("parameters/Rifle_Movement/conditions/is_crouching", sync_is_crouching)
	anim_tree.set("parameters/Rifle_Movement/conditions/is_standing", not sync_is_crouching)
	anim_tree.set("parameters/Rifle_Movement/conditions/is_falling", is_falling)
	anim_tree.set("parameters/Rifle_Movement/conditions/is_grounded", sync_is_grounded)


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
			print("Switching to Unarmed")
		elif event.keycode == KEY_2:
			current_weapon = WEAPON_RIFLE # 1
			print("Switching to Rifle")

func _physics_process(delta):
	# --- GRAVITY ---
	if not is_on_floor():
		velocity.y -= gravity * delta
		sync_is_grounded = false
	else:
		sync_is_grounded = true
		sync_is_jumping = false

	# --- JUMP ---
	if Input.is_action_just_pressed("jump") and is_on_floor() and not sync_is_crouching:
		velocity.y = JUMP_VELOCITY
		sync_is_jumping = true
		sync_is_grounded = false

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
