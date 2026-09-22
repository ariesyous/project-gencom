"""CI-safe episode baker: generate one episode via OpenRouter, synthesize its
audio via edge-tts, and write a static shows/ep{N}/episode.json + audio/*.mp3
bundle plus an updated shows/manifest.json. No live Godot connection, no
WebSocket, no sockets of any kind — this is a pure data-publish step meant to
run in a GitHub Action (see .github/workflows/bake-episode.yml).

Run once per invocation (one episode per CI run); scheduling cadence is the
workflow's cron, not a loop in here. For local manual bakes, just run this
script directly with OPENROUTER_API_KEY set.
"""
import asyncio
import json
import os
import random
from collections import deque
from datetime import datetime, timezone

from openai import OpenAI
import edge_tts

from audio_timing import mp3_duration

# --- Configuration ---
OPENROUTER_API_KEY = os.environ.get("OPENROUTER_API_KEY")
OPENROUTER_BASE_URL = "https://openrouter.ai/api/v1"
# Daily scheduled runs use this default; workflow_dispatch can override via
# the OPENROUTER_MODEL env var (see .github/workflows/bake-episode.yml),
# mirroring the pattern already used in github.com/ariesyous/openfeed.
MODEL_NAME = os.environ.get("OPENROUTER_MODEL", "openrouter/free")

SHOWS_DIR = "./shows"
MANIFEST_PATH = os.path.join(SHOWS_DIR, "manifest.json")
MEMORY_PATH = os.path.join(SHOWS_DIR, "_memory.json")
TOPIC_STATE_PATH = os.path.join(SHOWS_DIR, "_topic_state.json")

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

# Known set ids; the writer tags each skit with one. Anything else falls back to "apartment".
SCENES = ("apartment", "coffee_shop", "grocery")
DEFAULT_SCENE = "apartment"

MAX_SKITS_PER_EPISODE = 5  # soft clamp so a runaway episode can't play forever

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


async def generate_episode(client, topic, memory=(), attempts=3):
	"""Fetch a themed multi-skit episode from the LLM, retrying on empty/invalid
	responses (openrouter/free re-picks a random underlying model per call, and
	not every one of them reliably honors response_format=json_object — a
	retry usually lands on a model that does)."""
	for attempt in range(1, attempts + 1):
		episode = await _generate_episode_once(client, topic, memory)
		if episode:
			return episode
		if attempt < attempts:
			print(f"[Warning] Episode generation attempt {attempt}/{attempts} failed, retrying...")
			await asyncio.sleep(2.0)
	return None


async def _generate_episode_once(client, topic, memory=()):
	"""One attempt at fetching a themed multi-skit episode from the LLM.

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
	def call_llm():
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
		choice = completion.choices[0]
		if not choice.message.content:
			print(f"[Error] LLM returned empty content. finish_reason={choice.finish_reason!r} "
				f"full_choice={choice.model_dump()!r}")
		return choice.message.content

	try:
		raw_text = await loop.run_in_executor(None, call_llm)
		if not raw_text:
			return None
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
			print(f"[Error] Unexpected episode shape from LLM: {type(data).__name__}")
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
		print(f"[Error] Failed to fetch episode from LLM: {e}")
		return None


async def create_tts(text, voice_key, filepath):
	"""Generate local audio with edge-tts.

	edge-tts occasionally returns NO audio without raising, leaving a 0-byte
	file. A dead clip would wedge the stage the same way it could live, so we
	verify the file has real bytes and retry once before giving up.
	"""
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

	print(f"[Error] Skipping line — no audio produced after retry: {filepath}")
	return False


def _load_json(path, default):
	if os.path.exists(path):
		try:
			with open(path, "r", encoding="utf-8") as fh:
				return json.load(fh)
		except Exception:
			pass
	return default


def _save_json(path, data):
	with open(path, "w", encoding="utf-8") as fh:
		json.dump(data, fh, indent=2)


def _next_episode_id(manifest):
	n = len(manifest.get("episodes", [])) + 1
	# Keep counting up even if earlier episodes were pruned — never reuse an id.
	seen = {e["id"] for e in manifest.get("episodes", []) if "id" in e}
	while f"ep{n:04d}" in seen:
		n += 1
	return f"ep{n:04d}"


async def bake_one_episode() -> bool:
	"""Generate, voice, and write one episode + update the manifest. Returns
	True on success. Writes nothing on failure (no partial episode published)."""
	client = OpenAI(api_key=OPENROUTER_API_KEY, base_url=OPENROUTER_BASE_URL)
	os.makedirs(SHOWS_DIR, exist_ok=True)

	manifest = _load_json(MANIFEST_PATH, {"episodes": []})
	memory_list = _load_json(MEMORY_PATH, [])
	memory = deque(memory_list, maxlen=3)
	topic_state = _load_json(TOPIC_STATE_PATH, {"bag": [], "last_topic": None})
	topic_bag = topic_state.get("bag", [])
	last_topic = topic_state.get("last_topic")

	if not topic_bag:
		topic_bag = random.sample(TOPICS, len(TOPICS))
		if last_topic is not None and topic_bag[-1] == last_topic and len(topic_bag) > 1:
			topic_bag[0], topic_bag[-1] = topic_bag[-1], topic_bag[0]
	topic = topic_bag.pop()
	last_topic = topic

	print(f"=== Baking episode [{MODEL_NAME}] ===")
	print(f"[Brain] Topic: {topic}")

	episode = await generate_episode(client, topic, memory)
	if not episode:
		print("[Error] Invalid episode received; aborting bake (nothing published).")
		return False

	ep_id = _next_episode_id(manifest)
	ep_dir = os.path.join(SHOWS_DIR, ep_id)
	audio_dir = os.path.join(ep_dir, "audio")
	os.makedirs(audio_dir, exist_ok=True)

	skits = episode["skits"]
	print(f"[Brain] {ep_id} — \"{episode['theme']}\" ({len(skits)} skits)")

	events = []
	current_scene = DEFAULT_SCENE
	line_counter = 0
	any_line_ok = False

	for s, skit in enumerate(skits):
		scene = skit.get("scene", DEFAULT_SCENE)

		# Explicit scene-transition / stinger events, matching what used to be
		# decided live in orchestrator.py's main_loop.
		if scene != current_scene:
			events.append({"type": "set_scene", "scene": scene})
			current_scene = scene
		elif s > 0:
			events.append({"type": "play_stinger"})

		events.append({"type": "skit_boundary"})

		for entry in skit["lines"]:
			actor = entry.get("actor", "A")
			raw_line = entry.get("line", "")
			if not raw_line:
				continue
			has_laugh = "[LAUGH]" in raw_line
			line = raw_line.replace("[LAUGH]", "").strip()
			if not line:
				continue

			filename = f"line{line_counter:03d}.mp3"
			filepath = os.path.join(audio_dir, filename)
			line_counter += 1

			ok = await create_tts(line, actor, filepath)
			if not ok:
				continue
			any_line_ok = True
			duration = mp3_duration(filepath, default=max(2.5, len(line.split()) * 0.5))
			events.append({
				"type": "play_audio",
				"actor": actor,
				"file": f"audio/{filename}",
				"text": line,
				"laugh": has_laugh,
				"duration_s": round(duration, 2),
			})
			if has_laugh:
				events.append({"type": "trigger_laugh"})

	if not any_line_ok:
		print("[Error] No usable audio was produced for this episode; aborting bake.")
		return False

	episode_doc = {
		"id": ep_id,
		"theme": episode["theme"],
		"callback": episode.get("callback", ""),
		"generated_at": datetime.now(timezone.utc).isoformat(),
		"model": MODEL_NAME,
		"events": events,
	}
	_save_json(os.path.join(ep_dir, "episode.json"), episode_doc)

	manifest.setdefault("episodes", []).append({
		"id": ep_id,
		"theme": episode["theme"],
		"aired_at": episode_doc["generated_at"],
		"path": f"shows/{ep_id}/episode.json",
	})
	_save_json(MANIFEST_PATH, manifest)

	# Continuity persists across CI runs (it used to live only in the
	# long-running Python process's memory).
	memory.append({"theme": episode["theme"], "callback": episode.get("callback", "")})
	_save_json(MEMORY_PATH, list(memory))
	_save_json(TOPIC_STATE_PATH, {"bag": topic_bag, "last_topic": last_topic})

	print(f"[System] Baked {ep_id} ({line_counter} lines).")
	return True


if __name__ == "__main__":
	if not OPENROUTER_API_KEY:
		print("[Critical Error] OPENROUTER_API_KEY environment variable not set.")
		raise SystemExit(1)
	success = asyncio.run(bake_one_episode())
	raise SystemExit(0 if success else 1)
