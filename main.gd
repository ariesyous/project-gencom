extends Node3D

enum State { WANDERING, HEADING_TO_SEAT, SITTING, OFFSTAGE, ENTERING }

const WALK_ANIM := "walk_v3"
const IDLE_ANIM := "idle_v1"
const SIT_ANIM := "sit_v1"
const TALK_ANIM := "talk_v5"  # arm gestures while speaking (standing still only)
const SIT_BODY_Y := -0.44  # how far the body drops to rest on the couch
const ESTABLISH_PAN := 4.0  # seconds the camera slow-trucks across the exterior facade
const WALK_SPEED := 1.5
const ENTRANCE_SPEED := 3.4  # Kessler's burst-into-frame stride (walk anim is sped to match)

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
		"spawn_k": Vector3(80, 0, -3),  # Kessler's fallback spot inside the aisles
		# Where Kessler waits between appearances: past the east wall on the near
		# (audience) side, where the wide cam's frustum is only ~2.2m wide — fully
		# off-frame from the wide, the singles, and the ExteriorCam. CSG has no
		# collision, so he strides straight through the wall into frame.
		"spawn_k_off": Vector3(89.5, 0, 3.5),
		"wander_min": Vector3(74, 0, -4), "wander_max": Vector3(86, 0, 4),
	},
}

var actors := {}

# --- Episode sequencer -----------------------------------------------------
# Replaces the old live WebSocket link (Python orchestrator -> running Godot)
# with a self-contained player: fetch a baked "shows/manifest.json", pick an
# episode (random, or ?ep=<id> for a deep link), fetch its episode.json, and
# walk the flat `events` list, firing the same play_line/play_laugh/
# play_stinger/_set_scene functions the old socket dispatcher used to call.
# Pacing constants below mirror orchestrator.py's STINGER_GAP/LINE_PAUSE/etc,
# now driving playback locally instead of pacing WebSocket sends.
const SEQ_STINGER_GAP := 6.0
const SEQ_SKIT_INTRO_PAUSE := 1.5
const SEQ_LINE_PAUSE := 1.1
const SEQ_LAUGH_WAIT := 7.6
const SEQ_POST_LAUGH_PAUSE := 1.4
const SEQ_SCENE_HOLD := 1.5  # extra beat after _set_scene's own pan tween settles
const SEQ_RETRY_WAIT := 5.0  # backoff after a failed manifest/episode fetch
# Relative URLs ("shows/...") resolve fine under Web export (same-origin fetch
# against the current page), but native/editor builds have no "current page"
# to resolve against — HTTPRequest needs an absolute URL there. For local
# testing, serve the repo root with `python -m http.server 8000` and Play the
# scene in the editor.
const LOCAL_DEV_BASE_URL := "http://localhost:8000/"

var http_manifest: HTTPRequest
var http_episode: HTTPRequest
var http_audio: HTTPRequest
# GitHub Pages (and most static hosts) gzip every response. Godot's own
# HTTPRequest/HTTPClient on Web export mishandles that — the browser's fetch
# layer already transparently decompresses the body before Godot's WASM code
# sees it, but Godot's gzip-aware StreamPeerGZIP still tries to decompress it
# again and fails ("stream_peer_gzip.cpp" / RESULT_REQUEST_FAILED) — so on
# Web, all networking bypasses HTTPRequest entirely and goes through the
# browser's native fetch() via JavaScriptBridge instead (see _web_fetch_*).
var _web_fetch_next_id := 0
var _web_window: JavaScriptObject  # cached window interface, Web only
var episode_base_url := ""
var episode_events: Array = []
var episode_index := 0
# Set by request_episode() (called from JS via the browser menu) to interrupt
# the currently-playing episode and jump to a specific one.
var pending_forced_id := ""
var skip_current_episode := false

# Close-up camera currently tracking a speaking actor (null = wide shot).
var active_cam: Camera3D = null
var active_cam_target: Node3D = null

# On-screen subtitle (SubtitleLayer/SubtitleLabel). subtitle_actor is whose line
# is showing; the caption hides itself when that actor stops speaking.
const ACTOR_NAMES := {"A": "ALAN", "B": "BRIDGETTE", "K": "KESSLER"}
var subtitle_label: Label = null
var subtitle_actor := ""

func _ready() -> void:
	_init_actor("A", get_node_or_null("Alan"), "BodyA/AnimationAlan")
	_init_actor("B", get_node_or_null("Bridgette"), "BodyB/AnimationBridgette")
	# Kessler is a grocery-only neighbor: he lives permanently in the grocery
	# region and is never teleported with the couple (see fixed_scene below).
	_init_actor("K", get_node_or_null("Kessler"), "BodyK/AnimationKessler", "grocery")
	# He waits offstage (outside the grocery's east wall) and bursts into frame
	# on his first line of a grocery visit — see _kessler_enter.
	if actors.has("K"):
		actors["K"]["state"] = State.OFFSTAGE
		actors["K"]["node"].position = SCENES["grocery"]["spawn_k_off"]
		actors["K"]["target"] = actors["K"]["node"].position

	subtitle_label = get_node_or_null("SubtitleLayer/SubtitleLabel")

	if has_node("Alan/VoiceA"): $Alan/VoiceA.finished.connect(_on_voice_finished.bind("A"))
	if has_node("Bridgette/VoiceB"): $Bridgette/VoiceB.finished.connect(_on_voice_finished.bind("B"))
	if has_node("Kessler/VoiceK"): $Kessler/VoiceK.finished.connect(_on_voice_finished.bind("K"))

	http_manifest = HTTPRequest.new(); add_child(http_manifest)
	http_episode = HTTPRequest.new(); add_child(http_episode)
	http_audio = HTTPRequest.new(); add_child(http_audio)

	if OS.has_feature("web"):
		_web_window = JavaScriptBridge.get_interface("window")
		# Let the in-page menu (injected via html/head_include, see
		# export_presets.cfg) tell a running instance to jump to a specific
		# episode without reloading the page.
		_web_window.godot_load_episode = JavaScriptBridge.create_callback(_js_load_episode)

	_sequencer_main_loop()

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

	var head: Node3D = body.get_node_or_null("Head" + id) if body else node
	actors[id] = {
		"node": node,
		"body": body,
		"head": head,
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
		"speed": WALK_SPEED,
		"next_decision_time": now + randi_range(1000, 3000),
		"speaking": false,
		"speak_until": 0,
		# Reactions (code-driven, like the mouth/blinks — no clip animates the
		# head or the body's Y, so these can't fight the AnimationPlayer).
		"head_base_rot_x": head.rotation_degrees.x if head else 0.0,
		"react_kind": "",   # "" | "laugh" | "nod"
		"react_start": 0,
		"react_end": 0,
		"react_bob": 0.0,   # extra body-Y offset, folded into the sit/stand lerp
		"next_nod": now + randi_range(3000, 6000),
	}

func _process(delta: float) -> void:
	for id in actors:
		_update_actor(id, delta)
		_update_face(id)
		_update_reactions(id)
	_update_active_camera()
	# Single clearing point for the subtitle: it rides the same "speaking" flag
	# as the mouth flap, so both the finished signal and the speak_until watchdog
	# hide it automatically.
	if subtitle_actor != "" and actors.has(subtitle_actor) and not actors[subtitle_actor]["speaking"]:
		_hide_subtitle()

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

func _update_reactions(id: String) -> void:
	# Code-driven "listening" life, layered like the mouth/blinks: no body clip
	# animates the head or Body-Y, so these channels are safe to drive here.
	# - laugh: head tilts back + a little body bounce (fired by play_laugh)
	# - nod: two quick dips while a nearby actor is talking
	var data = actors[id]
	var head: Node3D = data["head"]
	if head == null:
		return
	var now = Time.get_ticks_msec()

	if now < data["react_end"]:
		var t: float = float(now - data["react_start"]) / float(data["react_end"] - data["react_start"])
		var env: float = sin(t * PI)  # ease in and back out over the react
		if data["react_kind"] == "laugh":
			head.rotation_degrees.x = data["head_base_rot_x"] + 12.0 * env
			data["react_bob"] = 0.05 * env * abs(sin(float(now - data["react_start"]) * 0.02))
		else:  # nod
			head.rotation_degrees.x = data["head_base_rot_x"] - 9.0 * abs(sin(t * PI * 2.0))
		return

	# Settle back to neutral once a react ends.
	data["react_bob"] = 0.0
	head.rotation_degrees.x = lerp(head.rotation_degrees.x, data["head_base_rot_x"], 0.2)

	# Occasionally nod along while someone nearby is talking (listener behavior).
	if data["speaking"] or data["state"] == State.OFFSTAGE or now < data["next_nod"]:
		return
	var other_id := _nearest_other_id(id)
	if other_id == "" or not actors[other_id]["speaking"]:
		return
	var dist: float = data["node"].position.distance_to(actors[other_id]["node"].position)
	if dist < 6.0 and randf() < 0.35:
		_start_react(id, "nod", 900)
	data["next_nod"] = now + randi_range(4000, 9000)

func _start_react(id: String, kind: String, duration_ms: int) -> void:
	var data = actors[id]
	var now = Time.get_ticks_msec()
	data["react_kind"] = kind
	data["react_start"] = now
	data["react_end"] = now + duration_ms

func _js_load_episode(args: Array) -> void:
	# Called from the in-page episode menu (injected via the Web export
	# preset's html/head_include, see export_presets.cfg) via JavaScriptBridge.
	if args.size() > 0:
		request_episode(str(args[0]))

func request_episode(id: String) -> void:
	pending_forced_id = id
	skip_current_episode = true

func _get_requested_episode_id() -> String:
	# Deep link support: ?ep=<id> in the page URL picks a specific episode on
	# first load instead of a random one.
	if not OS.has_feature("web"):
		return ""
	var qs = JavaScriptBridge.eval("window.location.search", true)
	if typeof(qs) != TYPE_STRING or not qs.begins_with("?"):
		return ""
	for pair in qs.substr(1).split("&"):
		var kv = pair.split("=")
		if kv.size() == 2 and kv[0] == "ep":
			return kv[1].uri_decode()
	return ""

func _resolve_url(path: String) -> String:
	# Godot's HTTPRequest (even under Web export) needs a fully absolute URL —
	# a browser-style relative path like "shows/manifest.json" fails with
	# "Invalid URL scheme" — so build one from the page's own location. This
	# also makes it work when the site is served from a subpath (e.g. GitHub
	# Pages' <user>.github.io/<repo>/), since it resolves against the page's
	# actual directory rather than assuming the domain root.
	if OS.has_feature("web"):
		var base = JavaScriptBridge.eval(
			"window.location.origin + window.location.pathname.replace(/[^/]*$/, '')", true)
		return str(base) + path
	return LOCAL_DEV_BASE_URL + path

func _web_fetch(kind: String, url: String) -> Variant:
	# Drives the browser's native fetch() via a JS function injected in
	# html/head_include (export_presets.cfg), since Godot's own HTTPRequest
	# can't be used for Web fetches here — GitHub Pages gzips responses, the
	# browser's fetch() already decompresses them, but Godot's own HTTPClient
	# on Web still tries to gzip-decode the already-decoded body and fails.
	# Returns raw text (kind="text") or a PackedByteArray decoded from base64
	# (kind="binary"), or null on failure.
	#
	# This polls a plain JS object via repeated eval() round-trips instead of
	# using JavaScriptBridge.create_callback() for the completion signal.
	# create_callback here reliably registered (typeof checks confirmed a
	# real bound function) and the triggering call never threw, but the
	# callback itself was never observed to fire for the async fetch
	# continuation — while plain JavaScriptBridge.eval() round-trips (queried
	# every frame) worked reliably in every isolated test. Root cause not
	# fully identified; polling sidesteps it entirely.
	var id := _web_fetch_next_id
	_web_fetch_next_id += 1
	var fn := "window.__webFetchText" if kind == "text" else "window.__webFetchBinary"
	JavaScriptBridge.eval("%s(%d, %s)" % [fn, id, JSON.stringify(url)], true)
	var res: Dictionary = {}
	while res.is_empty():
		await get_tree().process_frame
		var raw = JavaScriptBridge.eval("JSON.stringify(window.__webFetchResults[%d] || null)" % id, true)
		if typeof(raw) == TYPE_STRING and raw != "null":
			var json := JSON.new()
			if json.parse(raw) == OK and typeof(json.data) == TYPE_DICTIONARY:
				res = json.data
	JavaScriptBridge.eval("delete window.__webFetchResults[%d]" % id, true)
	if not res.get("ok", false):
		print("Sequencer: web fetch failed for ", url, " (", res.get("data", ""), ")")
		return null
	return res["data"] if kind == "text" else Marshalls.base64_to_raw(str(res["data"]))

func _fetch_json(req: HTTPRequest, path: String) -> Variant:
	# Fetch + parse a JSON document. Returns null on any failure.
	var url := _resolve_url(path)
	var raw_text
	if OS.has_feature("web"):
		raw_text = await _web_fetch("text", url)
		if raw_text == null:
			return null
	else:
		var err = req.request(url)
		if err != OK:
			print("Sequencer: failed to request ", url, " (", err, ")")
			return null
		var res: Array = await req.request_completed
		if res[0] != HTTPRequest.RESULT_SUCCESS or res[1] != 200:
			print("Sequencer: fetch failed for ", url, " (result=", res[0], " code=", res[1], ")")
			return null
		raw_text = res[3].get_string_from_utf8()
	var json := JSON.new()
	if json.parse(raw_text) != OK:
		print("Sequencer: bad JSON from ", url)
		return null
	return json.data

func _pick_episode(episodes: Array, forced_id: String) -> Variant:
	if forced_id != "":
		for e in episodes:
			if typeof(e) == TYPE_DICTIONARY and e.get("id", "") == forced_id:
				return e
	return episodes[randi() % episodes.size()]

func _sequencer_main_loop() -> void:
	# Single long-lived loop (not recursive) so playing episodes indefinitely
	# never grows the call/await stack. See CLAUDE.md "Episode sequencer".
	var forced_id := _get_requested_episode_id()
	while true:
		if pending_forced_id != "":
			forced_id = pending_forced_id
			pending_forced_id = ""
		skip_current_episode = false

		var manifest = await _fetch_json(http_manifest, "shows/manifest.json")
		var episodes: Array = manifest.get("episodes", []) if typeof(manifest) == TYPE_DICTIONARY else []
		if episodes.is_empty():
			await get_tree().create_timer(SEQ_RETRY_WAIT).timeout
			continue

		var chosen = _pick_episode(episodes, forced_id)
		forced_id = ""  # only honor the deep link/forced pick once

		var ep_path: String = chosen.get("path", "") if typeof(chosen) == TYPE_DICTIONARY else ""
		var episode = null
		if ep_path != "":
			episode = await _fetch_json(http_episode, ep_path)
		episode_events = episode.get("events", []) if typeof(episode) == TYPE_DICTIONARY else []
		if episode_events.is_empty():
			await get_tree().create_timer(SEQ_RETRY_WAIT).timeout
			continue
		episode_base_url = ep_path.get_base_dir() + "/"

		episode_index = 0
		while episode_index < episode_events.size() and not skip_current_episode:
			var ev = episode_events[episode_index]
			episode_index += 1
			if typeof(ev) == TYPE_DICTIONARY:
				await _handle_baked_event(ev)

		if not skip_current_episode:
			await get_tree().create_timer(SEQ_STINGER_GAP).timeout

func _handle_baked_event(ev: Dictionary) -> void:
	match ev.get("type", ""):
		"set_scene":
			await _set_scene(ev.get("scene", "apartment"))
			await get_tree().create_timer(SEQ_SCENE_HOLD).timeout
		"skit_boundary":
			await get_tree().create_timer(SEQ_SKIT_INTRO_PAUSE).timeout
		"play_audio":
			await _play_baked_line(ev)
		"trigger_laugh":
			play_laugh()
			await get_tree().create_timer(SEQ_LAUGH_WAIT + SEQ_POST_LAUGH_PAUSE).timeout
		"play_stinger":
			play_stinger()
			await get_tree().create_timer(SEQ_STINGER_GAP).timeout

func _play_baked_line(ev: Dictionary) -> void:
	var actor_id: String = ev.get("actor", "A")
	var file: String = ev.get("file", "")
	var text: String = str(ev.get("text", ""))
	if file == "" or not actors.has(actor_id):
		return
	var url := _resolve_url(episode_base_url + file)
	var bytes
	if OS.has_feature("web"):
		bytes = await _web_fetch("binary", url)
	else:
		var err = http_audio.request(url)
		if err != OK:
			print("Sequencer: failed to request audio ", file, " (", err, ")")
			return
		var res: Array = await http_audio.request_completed
		if res[0] != HTTPRequest.RESULT_SUCCESS or res[1] != 200:
			print("Sequencer: audio fetch failed for ", file)
			return
		bytes = res[3]
	if bytes == null:
		return
	play_line(bytes, actor_id, text)
	while actors[actor_id]["speaking"]:
		await get_tree().process_frame
	await get_tree().create_timer(SEQ_LINE_PAUSE).timeout

func _update_actor(id: String, delta: float) -> void:
	var data = actors[id]
	var node = data["node"]
	# With three actors the "roommate" is whoever is closest. Because the three
	# sets are far apart in world space, the nearest actor is naturally the one
	# sharing this actor's region (e.g. Kessler only ever pairs up in the grocery).
	var other_id := _nearest_other_id(id)
	var other_node: Node3D = actors[other_id]["node"] if other_id != "" else null

	match data["state"]:
		State.WANDERING, State.HEADING_TO_SEAT, State.ENTERING:
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
					if data["state"] == State.ENTERING:
						# Entrance complete: back to normal pace and pairing.
						data["state"] = State.WANDERING
						data["speed"] = WALK_SPEED
						data["anim"].speed_scale = 1.0
						if other_node:
							_face_roommate_instant(node, other_node)
					# Standing still: gesture while delivering a line, breathe otherwise.
					_play_body(data, TALK_ANIM if data["speaking"] else IDLE_ANIM)
		State.SITTING:
			_play_body(data, SIT_ANIM)
		State.OFFSTAGE:
			# Parked out of frame, waiting for an entrance cue.
			_play_body(data, IDLE_ANIM)

	# Smoothly drop onto / rise off the couch. react_bob (laugh bounce) rides the
	# same lerp so the body's Y is only ever written here.
	if data["body"]:
		var target_y = (SIT_BODY_Y if data["state"] == State.SITTING else 0.0) + data["react_bob"]
		data["body"].position.y = lerp(data["body"].position.y, target_y, min(1.0, 8.0 * delta))

	# Showmanship: Face roommate when talking (zero Y to avoid gimbal lock).
	# Not while ENTERING — he should face his stride, not twist mid-run.
	if data["speaking"] and other_node and data["state"] != State.ENTERING:
		var dir_to_roommate = other_node.position - node.position
		dir_to_roommate.y = 0
		if dir_to_roommate.length() > 0.1:
			var look_basis = Basis.looking_at(dir_to_roommate.normalized(), Vector3.UP)
			node.basis = node.basis.slerp(look_basis, 3.0 * delta)

	if Time.get_ticks_msec() > data["next_decision_time"]:
		_make_decision(id)
		data["next_decision_time"] = Time.get_ticks_msec() + randi_range(10000, 30000)

func _nearest_other_id(id: String) -> String:
	# Closest other actor by world distance (regions are far apart, so this keeps
	# pairings within a set without hard-coding the A/B pair).
	var node: Node3D = actors[id]["node"]
	var best := ""
	var best_d := INF
	for oid in actors:
		if oid == id:
			continue
		# A parked (offstage) actor isn't "in the room" — don't face or nod at
		# him through the wall.
		if actors[oid]["state"] == State.OFFSTAGE:
			continue
		var on: Node3D = actors[oid]["node"]
		var d := node.position.distance_squared_to(on.position)
		if d < best_d:
			best_d = d
			best = oid
	return best

func _scene_for(id: String) -> String:
	# An actor pinned to a set (Kessler -> grocery) always uses that set's
	# seats/wander bounds; everyone else follows the active scene.
	var fs: String = actors[id].get("fixed_scene", "")
	return fs if fs != "" else current_scene

func _play_body(data: Dictionary, anim_name: String) -> void:
	# Track the intended clip ourselves: a one-shot pose (sit) clears
	# current_animation when it finishes, which must NOT retrigger it.
	# Fall back to idle if a library is missing the clip (e.g. a partially
	# rolled-out new animation) instead of erroring every frame.
	if not data["anim"].has_animation(anim_name):
		anim_name = IDLE_ANIM
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
	# Offstage/entering actors don't make idle decisions — the entrance flow
	# owns their state until it hands back to WANDERING.
	if data["state"] == State.OFFSTAGE or data["state"] == State.ENTERING:
		return
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

func _kessler_enter() -> void:
	# Kramer-style entrance: stride briskly from the offstage park spot through
	# the east wall, stopping just short of the couple. walk_v3 is tuned for
	# WALK_SPEED, so the clip is sped up to match the pace (else he glides).
	var data = actors["K"]
	var cfg = SCENES["grocery"]
	var target: Vector3 = cfg["spawn_k"]
	if actors.has("A") and actors.has("B"):
		var mid: Vector3 = (actors["A"]["node"].position + actors["B"]["node"].position) * 0.5
		var away: Vector3 = data["node"].position - mid
		away.y = 0
		if away.length() > 0.1:
			target = mid + away.normalized() * 1.8  # pull up just short of the pair
	var wmin: Vector3 = cfg["wander_min"]
	var wmax: Vector3 = cfg["wander_max"]
	target = Vector3(clamp(target.x, wmin.x, wmax.x), 0, clamp(target.z, wmin.z, wmax.z))
	data["target"] = target
	data["state"] = State.ENTERING
	data["speed"] = ENTRANCE_SPEED
	data["anim"].speed_scale = ENTRANCE_SPEED / WALK_SPEED
	# Keep _make_decision from interrupting the walk (it also early-returns on
	# ENTERING; this covers the hand-off frame either way).
	data["next_decision_time"] = Time.get_ticks_msec() + 15000

func _make_mp3_stream(bytes: PackedByteArray) -> AudioStreamMP3:
	var stream := AudioStreamMP3.new()
	stream.data = bytes
	return stream

func play_line(mp3_bytes: PackedByteArray, actor_id: String, text: String = "") -> void:
	if not actors.has(actor_id):
		print("Sitcom: Ignoring play_audio for unknown actor '", actor_id, "'")
		return
	# Kessler's first line of a grocery visit is his cue: burst in from offstage,
	# already talking (the 3D voice approaching with him is part of the bit).
	if actor_id == "K" and current_scene == "grocery" and actors["K"]["state"] == State.OFFSTAGE:
		_kessler_enter()
	_switch_camera(actor_id)

	var stream := _make_mp3_stream(mp3_bytes)
	# An empty/corrupt clip has no length and would never fire `finished`,
	# leaving the mouth flapping forever. Skip it instead of getting stuck.
	if stream.get_length() <= 0.0:
		print("Sitcom: Ignoring empty/invalid clip for actor ", actor_id)
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
	# Only after the clip is confirmed playable — a skipped clip must never
	# leave a stuck caption on screen.
	_show_subtitle(actor_id, text)
	print("Sitcom: Playing line for Actor ", actor_id)

func _show_subtitle(actor_id: String, text: String) -> void:
	# Empty text (old clients) or a missing label (scene without the UI) => no caption.
	if subtitle_label == null or text == "":
		return
	subtitle_label.text = ACTOR_NAMES.get(actor_id, actor_id) + ": " + text
	subtitle_label.visible = true
	subtitle_actor = actor_id

func _hide_subtitle() -> void:
	if subtitle_label:
		subtitle_label.visible = false
	subtitle_actor = ""

func _switch_camera(actor_id: String) -> void:
	var cfg = SCENES[current_scene]
	# Each speaker has their own audience-side single ("cam_a"/"cam_b"/"cam_k").
	# A set without that actor's camera (e.g. Kessler outside the grocery) just
	# cuts wide.
	var cam := get_node_or_null(cfg.get("cam_" + actor_id.to_lower(), "")) as Camera3D
	if cam == null:
		_cut_to_wide()
		return
	# An entrance is always covered by the actor's single — the camera tracking
	# him striding into frame IS the shot; never roll wide over it.
	if actors[actor_id]["state"] == State.ENTERING or randf() < 0.7:
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
	# Laughs/stingers are small, fixed, non-generated sound effects — they stay
	# bundled in the exported PCK and load via res://, unlike episode dialogue
	# (which the sequencer fetches over HTTP; see _play_baked_line).
	# Must go through ResourceLoader, not FileAccess: exports only pack the
	# imported .mp3str (via the .import remap), never the raw .mp3 source, so
	# FileAccess finds nothing outside the editor.
	if not ResourceLoader.exists(audio_path): return
	var stream = load(audio_path) as AudioStream
	if not stream: return
	var player = get_node_or_null(node_path)
	if not player: return
	player.stream = stream
	player.play()

func play_laugh() -> void:
	_cut_to_wide()
	_play_clip(SCENES[current_scene]["laugh"], "res://audio/laugh" + str(randi_range(1, 4)) + ".mp3")
	# Everyone who isn't mid-line visibly enjoys the joke — durations are
	# randomized so the pair doesn't bob in lockstep.
	for id in actors:
		if not actors[id]["speaking"] and actors[id]["state"] != State.OFFSTAGE:
			_start_react(id, "laugh", randi_range(1100, 1700))

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
		# Set-pinned actors (Kessler) don't travel — every scene change re-parks
		# them offstage so the next visit gets a fresh entrance.
		if data.get("fixed_scene", "") != "":
			var home = SCENES[data["fixed_scene"]]
			data["node"].position = home.get("spawn_k_off", home.get("spawn_k", data["node"].position))
			data["state"] = State.OFFSTAGE
			data["target"] = data["node"].position
			data["cur_anim"] = ""
			data["speed"] = WALK_SPEED
			data["anim"].speed_scale = 1.0
			if data["body"]:
				data["body"].position.y = 0.0
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
