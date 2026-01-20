extends CharacterBody3D

# --- Settings ---
const WALK_SPEED = 2.0
const RUN_SPEED = 6.0
const CROUCH_SPEED = 1.0 
const JUMP_VELOCITY = 4.5
const MOUSE_SENSITIVITY = 0.006
const CAMERA_LAG_SPEED = 8.0  # <--- NEW: Controls how smooth the camera follows (Lower = Smoother)

const ACCELERATION = 10.0 
const DECELERATION = 4.0

const WEAPON_UNARMED = 0
const WEAPON_RIFLE = 1 

# --- Nodes ---
# NOTE: Make sure "CameraPivot" is now a child of the Player (CharacterBody3D), NOT the Skeleton!
@onready var camera_pivot: Node3D = $CameraPivot
@onready var camera: Camera3D = $CameraPivot/SpringArm3D/Camera3D
@onready var anim_tree = $AnimationTree
@onready var collision_shape = $CollisionShape3D 
@onready var spring_arm: SpringArm3D = $CameraPivot/SpringArm3D 

# NOTE: "HeadTarget" is the BoneAttachment3D inside your skeleton (renamed from "BoneAttachment3D")
@onready var head_target: Node3D = $soilder/Armature/Skeleton3D/HeadTarget

# --- NETWORK VARIABLES ---
@export var networked_velocity := Vector3.ZERO
@export var current_weapon := WEAPON_UNARMED 

@export var sync_is_grounded := true
@export var sync_is_jumping := false
@export var sync_is_crouching := false 

# --- INPUT VARIABLES ---
@export var is_armed := false # For switching weapons

var gravity = ProjectSettings.get_setting("physics/3d/default_gravity")
var default_height = 2.0 
var crouch_height = 1.0 

func _enter_tree():
	set_multiplayer_authority(name.to_int())

func _ready():
	if is_multiplayer_authority():
		camera.current = true
		# Exclude player body so camera doesn't clip inside
		$CameraPivot/SpringArm3D.add_excluded_object(self.get_rid())
		
		# DETACHMENT TRICK:
		# We make the CameraPivot top-level so it doesn't inherit the player's rotation automatically.
		# We will control it manually in code for maximum smoothness.
		camera_pivot.top_level = true
		
	else:
		set_physics_process(false)
		set_process_unhandled_input(false)

	anim_tree.active = true 
	
	if collision_shape.shape is CapsuleShape3D:
		default_height = collision_shape.shape.height

func _process(delta):
	if is_multiplayer_authority():
		networked_velocity = velocity
		# current_weapon = WEAPON_UNARMED  <-- Removed this so we can switch weapons!
	
	var world_velocity = networked_velocity 

	# --- 1. SET THE WEAPON ---
	# We update the animation tree with our boolean
	anim_tree.set("parameters/MainState/conditions/has_weapon", is_armed)
	anim_tree.set("parameters/MainState/conditions/no_weapon", not is_armed)

	# --- 2. MOVEMENT BLEND ---
	var local_velocity = transform.basis.inverse() * world_velocity
	
	var current_max_speed = WALK_SPEED
	if sync_is_crouching:
		current_max_speed = CROUCH_SPEED 
	elif local_velocity.z < 0 and abs(local_velocity.z) > WALK_SPEED:
		current_max_speed = RUN_SPEED

	var blend_x = local_velocity.x / current_max_speed
	var blend_z = local_velocity.z / current_max_speed
		
	var anim_blend = Vector2(blend_x, -blend_z)
	
	# Feed blend position to BOTH Normal and Pistol states so switching is seamless
	var current_blend = anim_tree.get("parameters/MainState/Movement/blend_position")
	if current_blend != null:
		anim_tree.set("parameters/MainState/Movement/blend_position", current_blend.lerp(anim_blend, 10 * delta))
		
	# Safe check: Only set pistol blend if the node exists
	if anim_tree.get("parameters/MainState/Pistol_Movement/blend_position") != null:
		anim_tree.set("parameters/MainState/Pistol_Movement/blend_position", current_blend.lerp(anim_blend, 10 * delta))

	# Crouch Movement
	var crouch_blend = anim_tree.get("parameters/MainState/Crouch_Movement/blend_position")
	if crouch_blend != null:
		anim_tree.set("parameters/MainState/Crouch_Movement/blend_position", crouch_blend.lerp(anim_blend, 10 * delta))
	
	# --- 3. UPDATE CONDITIONS ---
	anim_tree.set("parameters/MainState/conditions/is_grounded", sync_is_grounded)
	anim_tree.set("parameters/MainState/conditions/is_jumping", sync_is_jumping)
	anim_tree.set("parameters/MainState/conditions/is_crouching", sync_is_crouching)
	anim_tree.set("parameters/MainState/conditions/is_standing", not sync_is_crouching)
	
	# --- 4. HANDLE SHAPE ---
	var target_h = crouch_height if sync_is_crouching else default_height
	var new_height = move_toward(collision_shape.shape.height, target_h, 5.0 * delta)
	collision_shape.shape.height = new_height
	collision_shape.position.y = new_height / 2.0

func _unhandled_input(event):
	if not is_multiplayer_authority(): return
	
	if event is InputEventMouseMotion:
		# 1. Rotate Player Body (Left/Right)
		rotate_y(-event.relative.x * MOUSE_SENSITIVITY)
		
		# 2. Rotate SPRING ARM (Up/Down) - NOT the Pivot!
		spring_arm.rotate_x(-event.relative.y * MOUSE_SENSITIVITY)
		
		# 3. Clamp the Spring Arm's rotation so you don't break your neck
		spring_arm.rotation.x = clamp(spring_arm.rotation.x, deg_to_rad(-90), deg_to_rad(90))
		
	# Weapon Switching Input
	if Input.is_key_pressed(KEY_1):
		is_armed = false
	if Input.is_key_pressed(KEY_2):
		is_armed = true

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
	# 1. Get where the head IS right now
	var target_pos = head_target.global_position
	camera_pivot.global_position = camera_pivot.global_position.lerp(target_pos, CAMERA_LAG_SPEED * delta)
	
	# Force CameraPivot (Y-Axis) to match Player Direction
	camera_pivot.rotation.y = rotation.y

	# --- MOVEMENT LOCK ---
	var state_machine = anim_tree.get("parameters/MainState/playback")
	var current_node = state_machine.get_current_node()
	
	if current_node == "Stand_To_Crouch" or current_node == "Crouch_To_Stand":
		velocity.x = move_toward(velocity.x, 0, DECELERATION * delta)
		velocity.z = move_toward(velocity.z, 0, DECELERATION * delta)
		move_and_slide()
		return

	# --- MOVEMENT CALCULATION ---
	var input_dir = Input.get_vector("left", "right", "forward", "backward")
	var target_speed = WALK_SPEED
	
	if sync_is_crouching:
		target_speed = CROUCH_SPEED
		if input_dir.y > 0: input_dir.y = 0 # No backward crouch
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
