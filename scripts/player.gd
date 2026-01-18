extends CharacterBody3D

# --- Settings ---
const WALK_SPEED = 2.0
const RUN_SPEED = 6.0
const JUMP_VELOCITY = 3.5
const MOUSE_SENSITIVITY = 0.006

# --- Acceleration ---
const ACCELERATION = 10.0 
const DECELERATION = 4.0

# --- WEAPON CONSTANTS ---
const WEAPON_UNARMED = 0
const WEAPON_RIFLE = 1 

# --- Nodes ---
@onready var camera_pivot = $CameraPivot
@onready var camera = $CameraPivot/SpringArm3D/Camera3D
@onready var anim_tree = $AnimationTree

# --- NETWORK VARIABLES ---
@export var networked_velocity := Vector3.ZERO
@export var current_weapon := WEAPON_UNARMED 

## NEW SYNC VARIABLES ##
# We need to sync these so other players know when to play the Jump animation
@export var sync_is_grounded := true
@export var sync_is_jumping := false

var gravity = ProjectSettings.get_setting("physics/3d/default_gravity")
var last_position = Vector3.ZERO

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

func _process(delta):
	if is_multiplayer_authority():
		networked_velocity = velocity
		current_weapon = WEAPON_UNARMED 
	
	var world_velocity = networked_velocity 

	# --- 1. SET THE WEAPON ---
	anim_tree.set("parameters/WeaponManager/current", current_weapon)

	# --- 2. CALCULATE ANIMATION (BLEND SPACE) ---
	var local_velocity = transform.basis.inverse() * world_velocity
	
	var blend_x = local_velocity.x / WALK_SPEED
	var blend_z = 0.0
	
	if local_velocity.z < 0: 
		blend_z = local_velocity.z / RUN_SPEED
	else:
		blend_z = local_velocity.z / WALK_SPEED
		
	var anim_blend = Vector2(blend_x, -blend_z)
	
	var current_blend = anim_tree.get("parameters/MainState/Movement/blend_position")
	if current_blend == null: current_blend = Vector2.ZERO
	
	anim_tree.set("parameters/MainState/Movement/blend_position", current_blend.lerp(anim_blend, 10 * delta))
	
	## NEW ANIMATION LOGIC (MOVED FROM PHYSICS TO PROCESS) ##
	# This now runs on EVERYONE'S computer, ensuring the jump shows up.
	anim_tree.set("parameters/MainState/conditions/is_grounded", sync_is_grounded)
	anim_tree.set("parameters/MainState/conditions/is_jumping", sync_is_jumping)
	
	last_position = position

func _unhandled_input(event):
	if not is_multiplayer_authority(): return
	
	if event is InputEventMouseMotion:
		rotate_y(-event.relative.x * MOUSE_SENSITIVITY)
		camera_pivot.rotate_x(-event.relative.y * MOUSE_SENSITIVITY)
		camera_pivot.rotation.x = clamp(camera_pivot.rotation.x, deg_to_rad(-90), deg_to_rad(90))

func _physics_process(delta):
	# --- JUMP LOGIC ---
	# We update the sync variables here, and the network sends them to others
	if not is_on_floor():
		velocity.y -= gravity * delta
		sync_is_grounded = false # Update sync variable
	else:
		sync_is_grounded = true # Update sync variable
		sync_is_jumping = false # Update sync variable

	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = JUMP_VELOCITY
		sync_is_jumping = true # Update sync variable
		sync_is_grounded = false # Update sync variable

	# --- MOVEMENT ---
	var input_dir = Input.get_vector("left", "right", "forward", "backward")
	var direction = (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	
	var target_speed = WALK_SPEED
	if direction:
		if Input.is_action_pressed("sprint") and input_dir.y < 0:
			target_speed = RUN_SPEED
		velocity.x = move_toward(velocity.x, direction.x * target_speed, ACCELERATION * delta)
		velocity.z = move_toward(velocity.z, direction.z * target_speed, ACCELERATION * delta)
	else:
		velocity.x = move_toward(velocity.x, 0, DECELERATION * delta)
		velocity.z = move_toward(velocity.z, 0, DECELERATION * delta)

	move_and_slide()
