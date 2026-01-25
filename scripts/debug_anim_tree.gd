extends Node

# Attach this to your player temporarily to see all AnimationTree parameters
# Run once, check console, then remove

@onready var anim_tree = get_parent().get_node("AnimationTree")

func _ready():
	await get_tree().create_timer(1.0).timeout # Wait for tree to initialize
	print("\n========== ANIMATION TREE PARAMETERS ==========")
	print_parameters(anim_tree, "parameters")
	print("===============================================\n")

func print_parameters(tree: AnimationTree, base_path: String):
	# Get all parameter names
	var param_list = tree.get_parameter_list()
	
	for param in param_list:
		var param_name = param["name"]
		if param_name.begins_with(base_path):
			var value = tree.get(param_name)
			print("%s = %s (Type: %s)" % [param_name, value, type_string(typeof(value))])
