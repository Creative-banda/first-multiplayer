extends CharacterBody3D

# --- Settings ---
const WALK_SPEED = 2.0
const RUN_SPEED = 6.0
const CROUCH_SPEED = 1.0 
const JUMP_VELOCITY = 4.5
const MOUSE_SENSITIVITY = 0.006

const ACCELERATION = 10.0 
const DECELERATION = 4.0

const WEAPON_UNARMED = 0
const WEAPON_RIFLE = 1 

# --- Nodes ---
@onready var camera_pivot = $CameraPivot
@onready var camera = $CameraPivot/SpringArm3D/Camera3D
@onready var anim_tree = $AnimationTree
@onready var collision_shape = $CollisionShape3D 

# --- NETWORK VARIABLES ---
@export var networked_velocity := Vector3.ZERO
@export var current_weapon := WEAPON_UNARMED 

@export var sync_is_grounded := true
@export var sync_is_jumping := false
@export var sync_is_crouching := false 

var gravity = ProjectSettings.get_setting("physics/3d/default_gravity")
var default_height = 2.0 
var crouch_height = 1.0 

func _enter_tree():
	set_multiplayer_authority(name.to_int())

func _ready():
	if is_multiplayer_authority():
		camera.current = true
		$CameraPivot/SpringArm3D.add_excluded_object(self.get_rid())
	else:
		set_physics_process(false)
		set_process_unhandled_input(false)

	anim_tree.active = true 
	
	if collision_shape.shape is CapsuleShape3D:
		default_height = collision_shape.shape.height

func _process(delta):
	if is_multiplayer_authority():
		networked_velocity = velocity
		current_weapon = WEAPON_UNARMED 
	
	var world_velocity = networked_velocity 

	# --- 1. SET THE WEAPON ---
	anim_tree.set("parameters/WeaponManager/current", current_weapon)

	# --- 2. MOVEMENT BLEND ---
	var local_velocity = transform.basis.inverse() * world_velocity
	
	var current_max_speed = WALK_SPEED
	# Logic to scale animation speed correctly
	if sync_is_crouching:
		current_max_speed = CROUCH_SPEED 
	elif local_velocity.z < 0 and abs(local_velocity.z) > WALK_SPEED:
		current_max_speed = RUN_SPEED

	var blend_x = local_velocity.x / current_max_speed
	var blend_z = local_velocity.z / current_max_speed
		
	var anim_blend = Vector2(blend_x, -blend_z)
	
	# Standard Movement
	var current_blend = anim_tree.get("parameters/MainState/Movement/blend_position")
	if current_blend != null:
		anim_tree.set("parameters/MainState/Movement/blend_position", current_blend.lerp(anim_blend, 10 * delta))

	# Crouch Movement (Fixed the typo here: Added underscore)
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
		rotate_y(-event.relative.x * MOUSE_SENSITIVITY)
		camera_pivot.rotate_x(-event.relative.y * MOUSE_SENSITIVITY)
		camera_pivot.rotation.x = clamp(camera_pivot.rotation.x, deg_to_rad(-90), deg_to_rad(90))

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

	# --- CROUCH TOGGLE (Problem 1 Fix) ---
	# We use 'just_pressed' to flip the switch (Toggle) instead of holding
	if Input.is_action_just_pressed("crouch") and is_on_floor():
		sync_is_crouching = not sync_is_crouching

	# --- MOVEMENT LOCK (Problem 2 Fix) ---
	# Get the playback object to see which node is currently playing
	var state_machine = anim_tree.get("parameters/MainState/playback")
	var current_node = state_machine.get_current_node()
	
	# If we are in the middle of transitioning, force stop and skip movement logic
	if current_node == "Stand_To_Crouch" or current_node == "Crouch_To_Stand":
		velocity.x = move_toward(velocity.x, 0, DECELERATION * delta)
		velocity.z = move_toward(velocity.z, 0, DECELERATION * delta)
		move_and_slide()
		return # <--- Stop the function here!

	# --- MOVEMENT CALCULATION ---
	var input_dir = Input.get_vector("left", "right", "forward", "backward")
	var target_speed = WALK_SPEED
	
	if sync_is_crouching:
		target_speed = CROUCH_SPEED
		
		# (Problem 4 Fix) Prevent Backward Movement
		# If input is asking for backward (positive Y), kill it.
		if input_dir.y > 0:
			input_dir.y = 0
			
		# (Problem 3 Fix) Prevent Sprinting
		# We simply DO NOT check for the sprint key here.
		
	elif Input.is_action_pressed("sprint") and input_dir.y < 0:
		# We only allow sprint if we are NOT crouching
		target_speed = RUN_SPEED

	var direction = (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()

	if direction:
		velocity.x = move_toward(velocity.x, direction.x * target_speed, ACCELERATION * delta)
		velocity.z = move_toward(velocity.z, direction.z * target_speed, ACCELERATION * delta)
	else:
		velocity.x = move_toward(velocity.x, 0, DECELERATION * delta)
		velocity.z = move_toward(velocity.z, 0, DECELERATION * delta)

	move_and_slide()
