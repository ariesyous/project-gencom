import asyncio
import json
import os
import random
from collections import deque
from openai import OpenAI
import edge_tts
import websockets

from audio_timing import mp3_duration

# --- Configuration ---
# LLM REQUIREMENTS (for swapping providers/models) — measured with the o200k_base
# tokenizer (~±10%). generate_episode() is the ONLY LLM call: a single, STATELESS
# request (system + one short user message, no history, no retrieval), one per episode.
#   - Input : ~925 tok system prompt + ~20-110 tok user (grows with the "Previously on"
#             episode memory, up to 3 entries) + ~10 overhead = ~1030 tok worst case.
#   - Output: ~400 (min 3x4) / ~750 (typical 4x6) / ~1230 (max 5x8 lines) tok; capped at
#             max_tokens=2000. Per-episode total ~1.4k–2.2k tok.
#   - Context window needed: input + reserved output ~= ~3k tok. A 4k model suffices,
#     8k is comfortable; context length is NOT the binding constraint (nothing accumulates).
#   - Needs: JSON output (response_format=json_object below; the parser also tolerates
#     loose JSON) and decent instruction-following at a ~910-tok multi-constraint prompt.
#   - Throughput is trivial: ~1 call per several minutes (an episode plays out over its
#     TTS runtime). The system prompt is byte-identical every call -> ideal for prompt
#     caching on providers that bill it (Groq does not cache-discount).
GROQ_API_KEY = os.environ.get("GROQ_API_KEY")
GROQ_BASE_URL = "https://api.groq.com/openai/v1"
MODEL_NAME = "openai/gpt-oss-120b" # User suggested openai/gpt-oss-120b

GODOT_AUDIO_DIR = "./audio" 
GODOT_WS_URL = "ws://localhost:9000"

VOICES = {
	"A": "en-US-GuyNeural",
	"B": "en-US-JennyNeural",
	"K": "en-US-AndrewNeural",  # Kessler — eccentric grocery-store neighbor (distinct from Alan's Guy)
}

# Per-voice delivery tweaks passed straight to edge_tts.Communicate. Kessler talks
# fast and a touch higher — in character for the eccentric neighbor.
VOICE_STYLES = {
	"K": {"rate": "+15%", "pitch": "+3Hz"},
}

# Actors the writer may use. Kessler ("K") is grocery-only; stray K lines in any
# other set are demoted to Alan in _coerce_skit.
ACTORS = ("A", "B", "K")
KESSLER_SCENE = "grocery"

NUM_STINGERS = 6        # stinger1.mp3 .. stinger6.mp3 in ./audio
STINGER_GAP = 6.0       # act break; the next skit opens as the sting tails off
EPISODE_GAP = 9.5       # longer beat between whole episodes (after the warm closer)
SKIT_INTRO_PAUSE = 1.5  # beat before a new skit begins
LINE_PAUSE = 1.1        # natural beat after a line before the next (no talking over each other)
LAUGH_WAIT = 7.6        # cover the longest laugh clip (Godot picks one at random)
POST_LAUGH_PAUSE = 1.4  # actors wait for the laughter to settle before speaking
SCENE_TRANSITION_GAP = 5.5  # visual establishing shot: cut to the exterior facade,
							# slow-pan over the stinger, then cut inside (matches main.gd ESTABLISH_PAN + hold)

MAX_SKITS_PER_EPISODE = 5  # soft clamp so a runaway episode can't play forever

# Known set ids; the writer tags each skit with one. Anything else falls back to "apartment".
SCENES = ("apartment", "coffee_shop", "grocery")
DEFAULT_SCENE = "apartment"

# Curated rotation of episode topics. One is picked per episode (no immediate
# repeats); the model riffs an episode-long theme out of it. The user's named
# favorites lead the list.
TOPICS = [
	"The Sopranos (the show, its characters, gabagool, therapy with Dr. Melfi)",
	"The Matrix (red pill vs blue pill, simulation theory, 'there is no spoon')",
	"the films of Nicolas Cage (Con Air, Face/Off, National Treasure, his vibe)",
	"a slice of history (a specific era, invention, or strange historical event)",
	"a philosophy idea (stoicism, absurdism, the trolley problem, Plato's cave)",
	"music (a genre, an instrument, or a legendary artist and why they matter)",
	"space and astronomy (black holes, the planets, the scale of the universe)",
	"ancient mythology (Greek, Norse, or Egyptian gods and their petty drama)",
	"classic cinema (a beloved old film or a wild bit of movie-making trivia)",
	"the deep ocean (anglerfish, the Mariana Trench, creatures of the abyss)",
	"the TTC and Toronto streetcars (the 504, delays, the chime, the rocket)",
	"Drake and the 6ix (Toronto's music scene, the CN Tower, repping the city)",
	"surviving a Canadian winter (black ice, salt, the one nice week of summer)",
	"the CN Tower (the EdgeWalk, the glass floor, that revolving restaurant)",
	"aggressively polite Canadian manners (sorry, eh, holding every door)",
]

SYSTEM_PROMPT = (
	"You are the writer's room for a warm, witty sitcom about Alan and Bridgette, a late-20s couple "
	"who live together in downtown Toronto. Each request asks you to write a whole EPISODE built "
	"around a given topic.\n\n"
	"THE TWO CHARACTERS: Alan and Bridgette are genuinely fond of each other. They 'yes-and' each "
	"other, build on each other's bits, and clearly enjoy each other's company. NEVER write them as "
	"mean, sarcastic, or cutting; the humor comes from delight and shared curiosity, never from "
	"putting each other down.\n\n"
	"THE NEIGHBOR (use sparingly): Kessler is an eccentric, fast-talking neighbor — big entrances, "
	"wild theories, schemes that somehow work out. Alan and Bridgette are delighted (and slightly "
	"alarmed) whenever he turns up. He appears ONLY at the grocery store ('No Thrills'), and only in "
	"SOME episodes — never in the apartment or the coffee shop. When he shows up, give him a few punchy "
	"lines, then let him bow out; he is a spice, not a main course. Most episodes can skip him entirely.\n\n"
	"THE SETTING: The show is set in Toronto. The action happens across THREE locations, and a good "
	"episode moves between them as the story calls for it:\n"
	"- 'apartment' — their cozy home; couch banter, the kitchen, winding down.\n"
	"- 'coffee_shop' — 'Timmy Ho's', a Tim Hortons-style cafe; double-doubles, Timbits, lineups.\n"
	"- 'grocery' — 'No Thrills', a No Frills-style discount grocery store; carts, aisles, deals. This "
	"is the ONLY place the neighbor Kessler can appear.\n"
	"Lean lightly into Toronto flavor (the TTC, streetcars, winter, the 6ix) when it's natural — never "
	"force it.\n\n"
	"COMEDY CRAFT — this is the part that matters most:\n"
	"- Be SPECIFIC. Concrete, vivid details are funny; vague generalities are not. Name the actual "
	"thing, the exact number, the weirdly precise image.\n"
	"- ESCALATE across the episode. Each skit should push the premise a little further than the last.\n"
	"- Plant a RUNNING BIT (a callback, a recurring object, a phrase) early and PAY IT OFF in the "
	"final skit so the episode feels whole.\n"
	"- Comedy first, but weave in a few GENUINE, low-risk facts about the topic so the audience "
	"actually learns something. Only state facts you are confident are true; if unsure, keep it vague "
	"or make the uncertainty itself the joke. Never assert a confident-sounding fake fact.\n"
	"- The FINAL skit lands a warm, heartfelt button that ties the topic back to their friendship — "
	"sincere, not saccharine.\n\n"
	"DIALOGUE STYLE: Natural and fast-paced. Vary tempo — some lines short, some longer. Use '...' or "
	"'-' to suggest pauses or interruptions. Do NOT have them say each other's names constantly; only "
	"use names organically. Append '[LAUGH]' to the very end of ONLY the strongest punchlines (a few "
	"per episode, not every line).\n\n"
	"STRUCTURE: Write 3 to 5 skits. Each skit is 4-8 lines and has its own little setup -> escalation "
	"-> punchline shape. Together they form one coherent episode arc: hook -> exploration/banter -> "
	"escalation -> heartfelt wrap.\n\n"
	"LOCATIONS: Tag EACH skit with a 'scene' of \"apartment\", \"coffee_shop\", or \"grocery\". Let the "
	"episode move between locations when the story wants it (e.g. start home, head to Timmy Ho's, end "
	"at No Thrills) — but do NOT change location every single skit; consecutive skits often share a "
	"location. The two of them are always together in the same place.\n\n"
	"OUTPUT: Return STRICTLY a JSON object of this shape (no prose, no markdown):\n"
	"{\n"
	'  "theme": "a short, punchy angle on the topic",\n'
	'  "callback": "the running bit you planted, 8 words or fewer",\n'
	'  "skits": [\n'
	'    { "scene": "coffee_shop", "lines": [ {"actor": "A", "line": "..."}, {"actor": "B", "line": "..."} ] }\n'
	"  ]\n"
	"}\n"
	"'actor' is 'A' for Alan, 'B' for Bridgette, or 'K' for Kessler the neighbor (grocery skits ONLY). "
	"'scene' is one of \"apartment\", \"coffee_shop\", \"grocery\"."
)


def _coerce_skit(skit):
	"""Normalize one skit into {"scene": str, "lines": [{actor, line}, ...]}, or None."""
	scene = DEFAULT_SCENE
	lines = skit
	if isinstance(skit, dict):
		raw_scene = str(skit.get("scene", "")).strip().lower().replace(" ", "_")
		if raw_scene in SCENES:
			scene = raw_scene
		lines = skit.get("lines")
		if not isinstance(lines, list):
			# Single-key wrapper around the line array.
			for value in skit.values():
				if isinstance(value, list):
					lines = value
					break
	if not isinstance(lines, list):
		return None
	cleaned = []
	for ln in lines:
		if not (isinstance(ln, dict) and ln.get("line")):
			continue
		actor = str(ln.get("actor", "A")).strip().upper()
		if actor not in ACTORS:
			actor = "A"
		# Kessler only exists in the grocery; demote stray appearances elsewhere.
		if actor == "K" and scene != KESSLER_SCENE:
			actor = "A"
		cleaned.append({"actor": actor, "line": ln["line"]})
	if not cleaned:
		return None
	return {"scene": scene, "lines": cleaned}


async def generate_episode(client, topic, memory=()):
	"""Fetch a themed multi-skit episode from Groq.

	`memory` is a small rolling window of past episodes ({"theme", "callback"} dicts)
	offered to the writer as optional callback material — the show's only continuity.

	Returns {"theme": str, "callback": str, "skits": [{"scene": str, "lines": [...]}, ...]} or None.
	"""
	user_msg = f"Write the next episode. Topic: {topic}"
	if memory:
		prev = "; ".join(
			f"\"{m['theme']}\"" + (f" (bit: {m['callback']})" if m["callback"] else "")
			for m in memory
		)
		user_msg += (
			f"\nPreviously on: {prev}. Optionally work in ONE quick, natural callback "
			"to a past episode; skip it if it doesn't fit."
		)

	loop = asyncio.get_running_loop()
	def call_groq():
		completion = client.chat.completions.create(
			model=MODEL_NAME,
			messages=[
				{"role": "system", "content": SYSTEM_PROMPT},
				{"role": "user", "content": user_msg}
			],
			temperature=0.9,
			max_tokens=2000,
			response_format={"type": "json_object"}
		)
		return completion.choices[0].message.content

	try:
		raw_text = await loop.run_in_executor(None, call_groq)
		data = json.loads(raw_text)

		# Find the list of skits. Ideally data["skits"]; tolerate bare arrays and
		# other single-key wrappers the model occasionally returns.
		raw_skits = None
		theme = ""
		callback = ""
		if isinstance(data, list):
			raw_skits = data
		elif isinstance(data, dict):
			theme = str(data.get("theme", "")).strip()
			callback = str(data.get("callback", "")).strip()[:80]
			for key in ("skits", "episode", "scenes", "script"):
				if isinstance(data.get(key), list):
					raw_skits = data[key]
					break
			if raw_skits is None:
				for value in data.values():
					if isinstance(value, list):
						raw_skits = value
						break

		if not isinstance(raw_skits, list):
			print(f"[Error] Unexpected episode shape from Groq: {type(data).__name__}")
			return None

		skits = []
		for skit in raw_skits[:MAX_SKITS_PER_EPISODE]:
			coerced = _coerce_skit(skit)
			if coerced:
				skits.append(coerced)

		if not skits:
			print("[Error] Episode had no usable skits.")
			return None
		return {"theme": theme or topic, "callback": callback, "skits": skits}
	except Exception as e:
		print(f"[Error] Failed to fetch episode from Groq: {e}")
		return None

async def create_tts(text, voice_key, output_filename):
	"""Generate local audio with edge-tts.

	edge-tts occasionally returns NO audio without raising, leaving a 0-byte
	file. A dead clip wedges the stage (Godot starts "speaking" but the empty
	stream never fires `finished`), so we verify the file has real bytes and
	retry once before giving up.
	"""
	filepath = os.path.join(GODOT_AUDIO_DIR, output_filename)
	voice = VOICES.get(voice_key, VOICES["A"])
	style = VOICE_STYLES.get(voice_key, {})

	for attempt in range(2):
		try:
			communicate = edge_tts.Communicate(text, voice, **style)
			await communicate.save(filepath)
			if os.path.getsize(filepath) > 512:  # a real clip is tens of KB
				return True
			print(f"[Warning] Empty TTS for Actor {voice_key} (attempt {attempt + 1}): {text[:50]!r}")
		except Exception as e:
			print(f"[Error] Failed to generate TTS for Actor {voice_key}: {e}")
		await asyncio.sleep(0.6)  # brief backoff before the retry

	print(f"[Error] Skipping line — no audio produced after retry: {output_filename}")
	return False

async def notify_engine(filename, actor_id, text=""):
	"""Sends a WebSocket signal to the listening Godot client.

	`text` is the spoken line; Godot shows it as an on-screen subtitle while
	the actor speaks (older stages without the subtitle UI just ignore it)."""
	max_retries = 3
	for attempt in range(max_retries):
		try:
			async with websockets.connect(GODOT_WS_URL) as websocket:
				payload = {
					"event": "play_audio",
					"file": filename,
					"actor": actor_id,
					"text": text
				}
				await websocket.send(json.dumps(payload))
				await asyncio.sleep(1.0) # Hold for Godot to poll
				return True
		except Exception as e:
			if attempt == max_retries - 1:
				print(f"[Warning] Could not connect to Godot WebSocket after {max_retries} attempts: {e}")
			else:
				await asyncio.sleep(1.0) # Wait before retry
	return False

async def trigger_godot_laugh():
	"""Sends a signal to Godot to play a random laugh track."""
	try:
		async with websockets.connect(GODOT_WS_URL) as websocket:
			payload = {"event": "trigger_laugh"}
			await websocket.send(json.dumps(payload))
			await asyncio.sleep(0.5)
	except Exception as e:
		print(f"[Warning] Could not connect to Godot for laugh: {e}")

async def trigger_stinger():
	"""Sends a signal to Godot to play a random between-skit musical sting."""
	try:
		async with websockets.connect(GODOT_WS_URL) as websocket:
			payload = {"event": "play_stinger"}
			await websocket.send(json.dumps(payload))
			await asyncio.sleep(0.5)
	except Exception as e:
		print(f"[Warning] Could not connect to Godot for stinger: {e}")

async def set_scene(scene_id):
	"""Tells Godot to perform a visual establishing transition into a new location:
	cut to that set's exterior facade, slow-pan over a stinger, then cut inside."""
	try:
		async with websockets.connect(GODOT_WS_URL) as websocket:
			payload = {"event": "set_scene", "scene": scene_id}
			await websocket.send(json.dumps(payload))
			await asyncio.sleep(0.5)
	except Exception as e:
		print(f"[Warning] Could not connect to Godot for scene change: {e}")

async def play_line(entry, filename):
	"""TTS one line, push it to Godot, and wait out its real duration (+ laugh)."""
	actor = entry.get("actor", "A")
	raw_line = entry.get("line", "")
	if not raw_line:
		return

	has_laugh = "[LAUGH]" in raw_line
	line = raw_line.replace("[LAUGH]", "").strip()
	print(f"[Actor {actor}] {line}")

	if not await create_tts(line, actor, filename):
		return
	if not await notify_engine(filename, actor, line):
		print(f"[Error] Skipping line due to connection failure: {filename}")
		return

	# Wait for the line to finish (measured clip length, with a word-count fallback).
	word_count = len(line.split())
	clip_dur = mp3_duration(os.path.join(GODOT_AUDIO_DIR, filename), default=max(2.5, word_count * 0.5))
	await asyncio.sleep(max(0.0, clip_dur - 1.0) + LINE_PAUSE)

	if has_laugh:
		await asyncio.sleep(0.4)
		print("[System] Triggering Laugh Track...")
		await trigger_godot_laugh()  # holds ~0.5s
		await asyncio.sleep(max(0.0, LAUGH_WAIT - 0.5) + POST_LAUGH_PAUSE)


async def main_loop():
	print(f"=== Launching NYC Apartment Comedy Orchestrator [{MODEL_NAME}] ===")

	client = OpenAI(api_key=GROQ_API_KEY, base_url=GROQ_BASE_URL)

	if not os.path.exists(GODOT_AUDIO_DIR):
		os.makedirs(GODOT_AUDIO_DIR)

	episode_counter = 0
	last_topic = None
	topic_bag = []           # shuffle bag: every topic plays once before any repeats
	memory = deque(maxlen=3)  # rolling "Previously on" — themes + running bits of recent episodes
	current_scene = DEFAULT_SCENE  # Godot starts in the apartment

	while True:
		episode_counter += 1

		# Draw from the shuffle bag; on refill, keep the seam from repeating the
		# topic we just played by swapping it away from the top of the bag.
		if not topic_bag:
			topic_bag = random.sample(TOPICS, len(TOPICS))
			if last_topic is not None and topic_bag[-1] == last_topic and len(topic_bag) > 1:
				topic_bag[0], topic_bag[-1] = topic_bag[-1], topic_bag[0]
		topic = topic_bag.pop()
		last_topic = topic

		print(f"\n--- Scripting Episode #{episode_counter} ---")
		print(f"[Brain] Topic: {topic}")

		episode = await generate_episode(client, topic, memory)
		if not episode:
			print("[Error] Invalid episode received. Retrying shortly...")
			await asyncio.sleep(10)
			continue

		skits = episode["skits"]
		print(f"[Brain] Episode #{episode_counter} — \"{episode['theme']}\" ({len(skits)} skits)")

		for s, skit in enumerate(skits):
			scene = skit.get("scene", DEFAULT_SCENE)

			# Act break BEFORE each skit. If the location changed, play a visual
			# establishing shot into the new set (it carries its own stinger);
			# otherwise (and never before the very first skit) roll a plain sting.
			if scene != current_scene:
				print(f"[System] Establishing shot -> {scene}")
				await asyncio.sleep(0.5)
				await set_scene(scene)
				await asyncio.sleep(SCENE_TRANSITION_GAP)
				current_scene = scene
			elif s > 0:
				print("[System] Skit finished. Rolling stinger...")
				await asyncio.sleep(0.5)
				await trigger_stinger()
				await asyncio.sleep(STINGER_GAP)

			await asyncio.sleep(SKIT_INTRO_PAUSE)  # brief beat before the skit begins
			print(f"[Stage] Skit {s + 1}/{len(skits)} [{scene}]")

			for i, entry in enumerate(skit["lines"]):
				filename = f"ep{episode_counter}_skit{s}_line{i}.mp3"
				await play_line(entry, filename)

		# Remember this episode (appended only after it actually played, so it
		# never feeds into its own generation) for future "Previously on" hooks.
		memory.append({"theme": episode["theme"], "callback": episode.get("callback", "")})

		# Longer beat to separate whole episodes, with a sting to close the act.
		print("[System] Episode finished. Rolling stinger into the break...")
		await asyncio.sleep(0.5)
		await trigger_stinger()
		await asyncio.sleep(EPISODE_GAP)

if __name__ == "__main__":
	if not GROQ_API_KEY:
		print("[Critical Error] GROQ_API_KEY environment variable not set.")
	else:
		asyncio.run(main_loop())
