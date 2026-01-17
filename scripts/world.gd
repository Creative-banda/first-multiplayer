extends Node3D

var peer = ENetMultiplayerPeer.new()
@export var player_scene: PackedScene # Drag player.tscn here in inspector
@onready var spawn_points: Node3D = $SpawnPoints


func _on_host_pressed():
	# Create a server on port 1024
	peer.create_server(1024)
	multiplayer.multiplayer_peer = peer
	
	# Hide the menu so we can play
	$UI.hide()
	
	# Spawn the host's player immediately
	add_player(multiplayer.get_unique_id())
	
	# Listen for when other players join
	multiplayer.peer_connected.connect(add_player)
	
func _on_join_pressed():
	# Create a client connecting to localhost on port 1024
	peer.create_client("127.0.0.1", 1024)
	multiplayer.multiplayer_peer = peer
	$UI.hide()

func add_player(peer_id):
	var player = player_scene.instantiate()
	
	# 4. The Golden Rule: Name must match ID
	player.name = str(peer_id)
	
	# Random Spawn Logic
	var spot = spawn_points.get_children().pick_random()
	player.position = spot.position
	player.rotation = spot.rotation
	
	add_child(player)
