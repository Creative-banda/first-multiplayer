extends CharacterBody3D

# --- Settings ---
const WALK_SPEED = 2.0
const RUN_SPEED = 6.0
const JUMP_VELOCITY = 4.5
const MOUSE_SENSITIVITY = 0.006

# --- Acceleration ---
const ACCELERATION = 4.0 
const DECELERATION = 5.0

# --- Nodes ---
@onready var camera_pivot = $CameraPivot
@onready var camera = $CameraPivot/SpringArm3D/Camera3D
@onready var anim_tree = $AnimationTree
@export var networked_velocity := Vector3.ZERO

var gravity = ProjectSettings.get_setting("physics/3d/default_gravity")
var last_position = Vector3.ZERO

func _enter_tree():
	set_multiplayer_authority(name.to_int())

func _ready():
	if is_multiplayer_authority():
		camera.current = true
		$CameraPivot/SpringArm3D.add_excluded_object(self.get_rid())
		# Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		set_physics_process(false)
		set_process_unhandled_input(false)

	anim_tree.active = true 

func _process(delta):
	# --- 1. SYNC THE VELOCITY ---
	# If I am the owner, I update the network variable.
	# If I am the client, the network variable updates me!
	if is_multiplayer_authority():
		networked_velocity = velocity
	
	# Use the networked version for animation (it works for everyone)
	var world_velocity = networked_velocity 

	# --- 2. CALCULATE ANIMATION ---
	var local_velocity = transform.basis.inverse() * world_velocity
	
	var blend_x = local_velocity.x / WALK_SPEED
	var blend_z = 0.0
	
	if local_velocity.z < 0: 
		blend_z = local_velocity.z / RUN_SPEED
	else:
		blend_z = local_velocity.z / WALK_SPEED
		
	var anim_blend = Vector2(blend_x, -blend_z)
	
	# Smooth it out
	var current_blend = anim_tree.get("parameters/Movement/blend_position")
	if current_blend == null: current_blend = Vector2.ZERO
	
	anim_tree.set("parameters/Movement/blend_position", current_blend.lerp(anim_blend, 10 * delta))
	
	last_position = position

func _unhandled_input(event):
	if not is_multiplayer_authority(): return
	
	if event is InputEventMouseMotion:
		rotate_y(-event.relative.x * MOUSE_SENSITIVITY)
		camera_pivot.rotate_x(-event.relative.y * MOUSE_SENSITIVITY)
		camera_pivot.rotation.x = clamp(camera_pivot.rotation.x, deg_to_rad(-90), deg_to_rad(90))

func _physics_process(delta):
	if not is_on_floor():
		velocity.y -= gravity * delta

	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = JUMP_VELOCITY
		anim_tree.set("parameters/JumpShot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)

	var input_dir = Input.get_vector("left", "right", "forward", "backward")
	var direction = (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	
	# --- STRICT SPRINT LOGIC ---
	var target_speed = WALK_SPEED
	
	if direction:
		# Check Sprint Conditions:
		# 1. Must be holding Sprint Key
		# 2. Must be moving FORWARD (input_dir.y < 0)
		#    This allows Forward+Left and Forward+Right, but blocks Back, Left-Only, and Right-Only
		if Input.is_action_pressed("sprint") and input_dir.y < 0:
			target_speed = RUN_SPEED
		else:
			target_speed = WALK_SPEED
			
		velocity.x = move_toward(velocity.x, direction.x * target_speed, ACCELERATION * delta)
		velocity.z = move_toward(velocity.z, direction.z * target_speed, ACCELERATION * delta)
	else:
		velocity.x = move_toward(velocity.x, 0, DECELERATION * delta)
		velocity.z = move_toward(velocity.z, 0, DECELERATION * delta)

	move_and_slide()
