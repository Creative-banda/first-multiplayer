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
const WEAPON_RIFLE = 1   # Input 1 in WeaponManager

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

	# --- 2. WEAPON SWITCHING (THE FIX) ---
	# We talk to the "WeaponManager" Transition Node. 
	# 0 = Unarmed, 1 = Rifle
	anim_tree.set("parameters/WeaponManager/current", current_weapon)
	
	# --- 3. MOVEMENT BLEND ---
	var local_velocity = transform.basis.inverse() * world_velocity
	
	# === IK CONTROL ===
	var is_moving = local_velocity.length() > 0.1
	var target_influence = 0.0
	if current_weapon == WEAPON_RIFLE and not is_moving:
		target_influence = 0.7
	spine_ik.interpolation = move_toward(spine_ik.interpolation, target_influence, 5.0 * delta)
	
	# === BLEND CALCULATION ===
	var blend_x = local_velocity.x / RUN_SPEED
	var blend_z = local_velocity.z / RUN_SPEED
	var target_blend_vector = Vector2(blend_x, -blend_z)
	var lerp_speed = 8.0 * delta 
	
	# --- 4. UPDATE ANIMATIONS (PATH FIXES) ---
	
	# A. Unarmed Movement
	# Assuming inside "MainState" you have a BlendSpace2D named "Movement"
	var u_pos = anim_tree.get("parameters/MainState/Movement/blend_position")
	if u_pos != null:
		anim_tree.set("parameters/MainState/Movement/blend_position", u_pos.lerp(target_blend_vector, lerp_speed))
	
	# B. Rifle Stand (Based on your 2nd Image)
	# Look at the path: Rifle_Movement -> Rifle_Stand
	var r_pos = anim_tree.get("parameters/Rifle_Movement/Rifle_Stand/blend_position")
	if r_pos != null:
		anim_tree.set("parameters/Rifle_Movement/Rifle_Stand/blend_position", r_pos.lerp(target_blend_vector, lerp_speed))

	# C. Rifle Crouch (Based on your 2nd Image)
	var c_pos = anim_tree.get("parameters/Rifle_Movement/Rifle_Crouch/blend_position")
	if c_pos != null:
		anim_tree.set("parameters/Rifle_Movement/Rifle_Crouch/blend_position", c_pos.lerp(target_blend_vector, lerp_speed))
	
	# --- 5. CONDITIONS (Only for Rifle State Machine) ---
	# These conditions live INSIDE Rifle_Movement
	anim_tree.set("parameters/Rifle_Movement/conditions/is_crouching", sync_is_crouching)
	anim_tree.set("parameters/Rifle_Movement/conditions/is_standing", not sync_is_crouching)
	
	# --- 6. SHAPE ---
	var target_h = crouch_height if sync_is_crouching else default_height
	var new_height = move_toward(collision_shape.shape.height, target_h, 5.0 * delta)
	collision_shape.shape.height = new_height
	collision_shape.position.y = new_height / 2.0

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
