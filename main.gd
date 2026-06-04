extends Node3D

enum State { WANDERING, HEADING_TO_SEAT, SITTING }

const WALK_ANIM := "walk_v3"
const IDLE_ANIM := "idle_v1"
const SIT_ANIM := "sit_v1"
const SIT_BODY_Y := -0.44  # how far the body drops to rest on the couch
const ESTABLISH_PAN := 4.0  # seconds the camera slow-trucks across the exterior facade

# The three sets live as separate regions in world space (no visibility toggling,
# so the global sky/lights survive). Each scene knows its cameras, seats, where the
# actors spawn, and how far they may wander. Seat paths "" => actors only wander.
# spawn_*/wander_* are WORLD-space (regions are offset on X); cameras/seats resolve
# globally via their node paths. See CLAUDE.md for the architecture notes.
var current_scene := "apartment"
var SCENES := {
	"apartment": {
		"wide": "ApartmentEnvironment/Camera3D",
		"cam_a": "ApartmentEnvironment/CameraAlan",
		"cam_b": "ApartmentEnvironment/CameraBridgette",
		"exterior_cam": "ApartmentEnvironment/ExteriorCam",
		"laugh": "ApartmentEnvironment/LaughPlayer",
		"seat_a": "ApartmentEnvironment/CouchBase/Seat1",
		"seat_b": "ApartmentEnvironment/CouchBase/Seat2",
		"spawn_a": Vector3(-2, 0, -2), "spawn_b": Vector3(2, 0, -2),
		"wander_min": Vector3(-6, 0, -4), "wander_max": Vector3(6, 0, 4),
	},
	"coffee_shop": {
		"wide": "CoffeeShopEnvironment/Camera3D",
		"cam_a": "CoffeeShopEnvironment/CameraAlan",
		"cam_b": "CoffeeShopEnvironment/CameraBridgette",
		"exterior_cam": "CoffeeShopEnvironment/ExteriorCam",
		"laugh": "CoffeeShopEnvironment/LaughPlayer",
		"seat_a": "CoffeeShopEnvironment/CafeTable/SeatC1",
		"seat_b": "CoffeeShopEnvironment/CafeTable/SeatC2",
		"spawn_a": Vector3(38, 0, -2), "spawn_b": Vector3(42, 0, -2),
		"wander_min": Vector3(34, 0, -4), "wander_max": Vector3(46, 0, 4),
	},
	"grocery": {
		"wide": "GroceryEnvironment/Camera3D",
		"cam_a": "GroceryEnvironment/CameraAlan",
		"cam_b": "GroceryEnvironment/CameraBridgette",
		"cam_k": "GroceryEnvironment/CameraKessler",  # Kessler only ever speaks here
		"exterior_cam": "GroceryEnvironment/ExteriorCam",
		"laugh": "GroceryEnvironment/LaughPlayer",
		"seat_a": "", "seat_b": "",  # no seats — they wander the aisles
		"spawn_a": Vector3(78, 0, -2), "spawn_b": Vector3(82, 0, -2),
		"spawn_k": Vector3(80, 0, -3),  # Kessler's home spot (matches his .tscn position)
		"wander_min": Vector3(74, 0, -4), "wander_max": Vector3(86, 0, 4),
	},
}

var server := TCPServer.new()
var socket := WebSocketPeer.new()
var port := 9000
var client_connected := false

var actors := {}

# Close-up camera currently tracking a speaking actor (null = wide shot).
var active_cam: Camera3D = null
var active_cam_target: Node3D = null

func _ready() -> void:
	_init_actor("A", get_node_or_null("Alan"), "BodyA/AnimationAlan")
	_init_actor("B", get_node_or_null("Bridgette"), "BodyB/AnimationBridgette")
	# Kessler is a grocery-only neighbor: he lives permanently in the grocery
	# region and is never teleported with the couple (see fixed_scene below).
	_init_actor("K", get_node_or_null("Kessler"), "BodyK/AnimationKessler", "grocery")

	if has_node("Alan/VoiceA"): $Alan/VoiceA.finished.connect(_on_voice_finished.bind("A"))
	if has_node("Bridgette/VoiceB"): $Bridgette/VoiceB.finished.connect(_on_voice_finished.bind("B"))
	if has_node("Kessler/VoiceK"): $Kessler/VoiceK.finished.connect(_on_voice_finished.bind("K"))

	var err = server.listen(port)
	if err != OK:
		print("WebSocket Server: Error listening on ", port)
	else:
		print("WebSocket Server: Listening on ", port)

func _init_actor(id: String, node: Node3D, anim_path: String, fixed_scene: String = "") -> void:
	if not node: return
	var body := node.get_node_or_null("Body" + id) as Node3D
	var now := Time.get_ticks_msec()

	# Collect the facial parts so the mouth and eyes can be driven from code.
	var mouth = body.get_node_or_null("Mouth" + id) if body else null
	var eyes: Array = []
	var eye_base: Array = []
	if body:
		for en in ["EyeWhiteL" + id, "EyeWhiteR" + id, "PupilL" + id, "PupilR" + id]:
			var e := body.get_node_or_null(en) as Node3D
			if e:
				eyes.append(e)
				eye_base.append(e.scale.y)

	actors[id] = {
		"node": node,
		"body": body,
		"head": body.get_node_or_null("Head" + id) if body else node,
		"anim": get_node(str(node.name) + "/" + anim_path),
		"voice": node.get_node_or_null("Voice" + id),
		"fixed_scene": fixed_scene,  # "" => follows current_scene; else pinned to one set
		"mouth": mouth,
		"mouth_base_y": mouth.scale.y if mouth else 0.025,
		"eyes": eyes,
		"eye_base": eye_base,
		"next_blink": now + randi_range(1500, 4000),
		"blink_end": 0,
		"state": State.WANDERING,
		"target": node.position,
		"speed": 1.5,
		"next_decision_time": now + randi_range(1000, 3000),
		"speaking": false,
		"speak_until": 0
	}

func _process(delta: float) -> void:
	_handle_network()
	for id in actors:
		_update_actor(id, delta)
		_update_face(id)
	_update_active_camera()

func _update_active_camera() -> void:
	# Keep the active close-up framed on the speaking actor's head as they move.
	if active_cam == null or not is_instance_valid(active_cam_target):
		return
	var look_pos = active_cam_target.global_position
	if active_cam.global_position.distance_to(look_pos) > 0.05:
		active_cam.look_at(look_pos, Vector3.UP)

func _update_face(id: String) -> void:
	var data = actors[id]
	var now = Time.get_ticks_msec()

	# Watchdog: force-clear a "speaking" state that outlived its clip (e.g. if the
	# AudioStreamPlayer's `finished` signal never arrived for a degenerate clip).
	if data["speaking"] and data["speak_until"] > 0 and now > data["speak_until"]:
		data["speaking"] = false

	# Mouth: open/close flap while speaking, settle closed otherwise.
	var mouth = data["mouth"]
	if mouth:
		if data["speaking"]:
			mouth.scale.y = data["mouth_base_y"] + abs(sin(now * 0.018)) * 0.09
		else:
			mouth.scale.y = lerp(mouth.scale.y, data["mouth_base_y"], 0.25)

	# Blink: briefly squash the eyes flat on a randomized timer.
	var eyes = data["eyes"]
	var closing = now < data["blink_end"]
	for i in eyes.size():
		eyes[i].scale.y = (data["eye_base"][i] * 0.12) if closing else data["eye_base"][i]
	if now >= data["blink_end"] and now >= data["next_blink"]:
		data["blink_end"] = now + 110
		data["next_blink"] = now + randi_range(2400, 5600)

func _handle_network() -> void:
	if server.is_connection_available():
		var conn = server.take_connection()
		if client_connected:
			socket.close()
		socket.accept_stream(conn)
		client_connected = true
		print("WebSocket Server: New client connected!")

	if client_connected:
		socket.poll()
		var ws_state = socket.get_ready_state()
		if ws_state == WebSocketPeer.STATE_OPEN:
			while socket.get_available_packet_count() > 0:
				var packet = socket.get_packet()
				var data_string = packet.get_string_from_utf8()
				_handle_json_packet(data_string)
		elif ws_state == WebSocketPeer.STATE_CLOSED or ws_state == WebSocketPeer.STATE_CLOSING:
			client_connected = false
			print("WebSocket Server: Client disconnected.")

func _update_actor(id: String, delta: float) -> void:
	var data = actors[id]
	var node = data["node"]
	# With three actors the "roommate" is whoever is closest. Because the three
	# sets are far apart in world space, the nearest actor is naturally the one
	# sharing this actor's region (e.g. Kessler only ever pairs up in the grocery).
	var other_node = _nearest_other(id)

	match data["state"]:
		State.WANDERING, State.HEADING_TO_SEAT:
			var diff = data["target"] - node.position
			diff.y = 0

			if diff.length() > 0.1:
				var dir = diff.normalized()
				node.position += dir * data["speed"] * delta

				# Face movement direction
				var target_basis = Basis.looking_at(dir, Vector3.UP)
				node.basis = node.basis.slerp(target_basis, 5.0 * delta)
				_play_body(data, WALK_ANIM)
			else:
				if data["state"] == State.HEADING_TO_SEAT:
					data["state"] = State.SITTING
					if other_node:
						_face_roommate_instant(node, other_node)
				else:
					_play_body(data, IDLE_ANIM)
		State.SITTING:
			_play_body(data, SIT_ANIM)

	# Smoothly drop onto / rise off the couch.
	if data["body"]:
		var target_y = SIT_BODY_Y if data["state"] == State.SITTING else 0.0
		data["body"].position.y = lerp(data["body"].position.y, target_y, min(1.0, 8.0 * delta))

	# Showmanship: Face roommate when talking (zero Y to avoid gimbal lock)
	if data["speaking"] and other_node:
		var dir_to_roommate = other_node.position - node.position
		dir_to_roommate.y = 0
		if dir_to_roommate.length() > 0.1:
			var look_basis = Basis.looking_at(dir_to_roommate.normalized(), Vector3.UP)
			node.basis = node.basis.slerp(look_basis, 3.0 * delta)

	if Time.get_ticks_msec() > data["next_decision_time"]:
		_make_decision(id)
		data["next_decision_time"] = Time.get_ticks_msec() + randi_range(10000, 30000)

func _nearest_other(id: String) -> Node3D:
	# Closest other actor by world distance (regions are far apart, so this keeps
	# pairings within a set without hard-coding the A/B pair).
	var node: Node3D = actors[id]["node"]
	var best: Node3D = null
	var best_d := INF
	for oid in actors:
		if oid == id:
			continue
		var on: Node3D = actors[oid]["node"]
		var d := node.position.distance_squared_to(on.position)
		if d < best_d:
			best_d = d
			best = on
	return best

func _scene_for(id: String) -> String:
	# An actor pinned to a set (Kessler -> grocery) always uses that set's
	# seats/wander bounds; everyone else follows the active scene.
	var fs: String = actors[id].get("fixed_scene", "")
	return fs if fs != "" else current_scene

func _play_body(data: Dictionary, anim_name: String) -> void:
	# Track the intended clip ourselves: a one-shot pose (sit) clears
	# current_animation when it finishes, which must NOT retrigger it.
	if data.get("cur_anim", "") != anim_name:
		data["cur_anim"] = anim_name
		data["anim"].play(anim_name)

func _face_roommate_instant(node: Node3D, other_node: Node3D) -> void:
	# Snap to face the roommate (zero Y to avoid gimbal lock).
	var dir_to_roommate = other_node.position - node.position
	dir_to_roommate.y = 0
	if dir_to_roommate.length() > 0.1:
		node.look_at(node.position + dir_to_roommate.normalized(), Vector3.UP)

func _make_decision(id: String) -> void:
	var data = actors[id]
	var cfg = SCENES[_scene_for(id)]
	var roll = randf()
	var seat_path: String = ""
	if id == "A":
		seat_path = cfg.get("seat_a", "")
	elif id == "B":
		seat_path = cfg.get("seat_b", "")  # Kessler (and any seatless set) just wanders
	if roll < 0.1 and seat_path != "":
		data["state"] = State.HEADING_TO_SEAT
		var seat = get_node_or_null(seat_path)
		if seat:
			data["target"] = seat.global_position
			data["target"].y = 0
	elif roll < 0.9:
		# Wander within this set's bounds (seatless sets like the grocery land here too).
		data["state"] = State.WANDERING
		var wmin: Vector3 = cfg["wander_min"]
		var wmax: Vector3 = cfg["wander_max"]
		data["target"] = Vector3(randf_range(wmin.x, wmax.x), 0, randf_range(wmin.z, wmax.z))

func _handle_json_packet(json_text: String) -> void:
	var json = JSON.new()
	if json.parse(json_text) == OK:
		var data = json.data
		if typeof(data) == TYPE_DICTIONARY:
			if data.get("event") == "play_audio":
				play_line(data.get("file", ""), data.get("actor", "A"))
			elif data.get("event") == "trigger_laugh":
				play_laugh()
			elif data.get("event") == "play_stinger":
				play_stinger()
			elif data.get("event") == "set_scene":
				_set_scene(data.get("scene", "apartment"))
			elif data.get("event") == "park_cam":
				_park_exterior_cam(data.get("scene", "apartment"))

func play_line(file_name: String, actor_id: String) -> void:
	if not actors.has(actor_id):
		print("Sitcom: Ignoring play_audio for unknown actor '", actor_id, "'")
		return
	_switch_camera(actor_id)

	var path = "res://audio/" + file_name
	if not FileAccess.file_exists(path):
		path = "res://" + file_name
		if not FileAccess.file_exists(path): return

	var file = FileAccess.open(path, FileAccess.READ)
	if file:
		var stream = AudioStreamMP3.new()
		stream.data = file.get_buffer(file.get_length())
		# An empty/corrupt clip has no length and would never fire `finished`,
		# leaving the mouth flapping forever. Skip it instead of getting stuck.
		if stream.get_length() <= 0.0:
			print("Sitcom: Ignoring empty/invalid clip: ", file_name)
			return
		var voice_node = actors[actor_id].get("voice")
		if voice_node:
			voice_node.stream = stream
			voice_node.play()

		# Mouth flap is driven by _update_face while "speaking" is true;
		# the body keeps its idle/walk/sit animation underneath.
		# speak_until is a watchdog: if `finished` somehow never fires, the mouth
		# still settles closed once the clip's duration (plus a margin) elapses.
		actors[actor_id]["speaking"] = true
		actors[actor_id]["speak_until"] = Time.get_ticks_msec() + int(stream.get_length() * 1000.0) + 800
		print("Sitcom: Playing line for Actor ", actor_id, ": ", file_name)

func _switch_camera(actor_id: String) -> void:
	var cfg = SCENES[current_scene]
	# Each speaker has their own audience-side single ("cam_a"/"cam_b"/"cam_k").
	# A set without that actor's camera (e.g. Kessler outside the grocery) just
	# cuts wide.
	var cam := get_node_or_null(cfg.get("cam_" + actor_id.to_lower(), "")) as Camera3D
	if cam == null:
		_cut_to_wide()
		return
	if randf() < 0.7:
		# Fixed audience-side "single" that pans to the speaker (multi-cam
		# sitcom style) — positioned past the open fourth wall, so an actor
		# can never wander into it. Framing is handled by _update_active_camera.
		cam.make_current()
		active_cam = cam
		active_cam_target = actors[actor_id]["head"]
	else:
		_cut_to_wide()

func _cut_to_wide() -> void:
	# Cut to the current scene's wide establishing shot and drop close-up tracking.
	var wide := get_node_or_null(SCENES[current_scene]["wide"]) as Camera3D
	if wide:
		wide.make_current()
	active_cam = null
	active_cam_target = null

func _play_clip(node_path: String, audio_path: String) -> void:
	# Load an mp3 off disk and play it through the given AudioStreamPlayer node.
	if not FileAccess.file_exists(audio_path): return
	var file = FileAccess.open(audio_path, FileAccess.READ)
	if not file: return
	var player = get_node_or_null(node_path)
	if not player: return
	var stream = AudioStreamMP3.new()
	stream.data = file.get_buffer(file.get_length())
	player.stream = stream
	player.play()

func play_laugh() -> void:
	_cut_to_wide()
	_play_clip(SCENES[current_scene]["laugh"], "res://audio/laugh" + str(randi_range(1, 4)) + ".mp3")

func play_stinger() -> void:
	# Between-skit musical sting: cut to the wide establishing shot.
	_cut_to_wide()
	_play_stinger_sound()

func _play_stinger_sound() -> void:
	# Just the music — used both by play_stinger and by scene-change establishing shots.
	_play_clip("StingerPlayer", "res://audio/stinger" + str(randi_range(1, 6)) + ".mp3")

func _set_scene(scene_id: String) -> void:
	# Visual establishing shot: cut to the destination set's exterior facade, slow-truck
	# the camera across it under a stinger, then teleport the actors in and cut inside.
	if not SCENES.has(scene_id):
		print("Sitcom: Ignoring set_scene for unknown scene '", scene_id, "'")
		return
	var cfg = SCENES[scene_id]
	active_cam = null
	active_cam_target = null
	_play_stinger_sound()

	var ext := get_node_or_null(cfg["exterior_cam"]) as Camera3D
	if ext:
		ext.make_current()
		var start := ext.position
		var end := start + ext.transform.basis.x * 2.0  # slow lateral truck across the facade
		var tw := create_tween()
		tw.tween_property(ext, "position", end, ESTABLISH_PAN).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		await tw.finished
		ext.position = start  # reset framing for next time
	else:
		await get_tree().create_timer(ESTABLISH_PAN).timeout

	_teleport_to_scene(scene_id)
	current_scene = scene_id
	_cut_to_wide()

func _park_exterior_cam(scene_id: String) -> void:
	# Dev hook (not used in normal playback): hold a single set's ExteriorCam indefinitely
	# so a clean facade still can be grabbed. Unlike _set_scene, there is no pan tween, no
	# actor teleport, and no _cut_to_wide — the camera just stays put until another event.
	if not SCENES.has(scene_id):
		print("Sitcom: Ignoring park_cam for unknown scene '", scene_id, "'")
		return
	var ext := get_node_or_null(SCENES[scene_id]["exterior_cam"]) as Camera3D
	if ext:
		ext.make_current()
	active_cam = null
	active_cam_target = null

func _teleport_to_scene(scene_id: String) -> void:
	# Drop both actors into the new region (hidden behind the establishing shot).
	var cfg = SCENES[scene_id]
	for id in actors:
		var data = actors[id]
		# Set-pinned actors (Kessler) stay home; only the couple travels.
		if data.get("fixed_scene", "") != "":
			continue
		var node: Node3D = data["node"]
		node.position = cfg["spawn_a"] if id == "A" else cfg["spawn_b"]
		data["state"] = State.WANDERING
		data["target"] = node.position
		data["cur_anim"] = ""  # force walk/idle re-evaluation in the new spot
		data["next_decision_time"] = Time.get_ticks_msec() + randi_range(2000, 5000)
		if data["body"]:
			data["body"].position.y = 0.0

func _on_voice_finished(id: String) -> void:
	if actors.has(id):
		actors[id]["speaking"] = false
		actors[id]["speak_until"] = 0
