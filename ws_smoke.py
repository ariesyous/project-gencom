"""Dependency-free WebSocket smoke test for the Sitcom Studio stage.

Drives the running Godot scene WITHOUT Groq/TTS: it replays audio files already
in ./audio and chains a few short skits (with laughs + between-skit stingers).
Timing waits each line's *actual* measured duration so the actors never talk
over each other, lets the laugh fully play out, and adds natural pauses.

Usage:
    1. Press Play in Godot (starts the WebSocket server on :9000).
    2. python ws_smoke.py

Requires only `websockets` (already used by orchestrator.py).
"""
import asyncio
import json
import os

import websockets

from audio_timing import mp3_duration

GODOT_WS_URL = "ws://localhost:9000"
AUDIO_DIR = "audio"

# Pacing (seconds).
SEND_HOLD = 1.0             # connection held open so Godot polls the packet
LINE_PAUSE = 1.1            # natural beat after a line before the next one
LAUGH_WAIT = 7.6            # covers the longest laugh clip (Godot picks at random)
POST_LAUGH_PAUSE = 1.4      # actors wait for the laughter to settle
STINGER_GAP = 6.0           # same-location act break; next skit opens as the sting tails
SCENE_TRANSITION_GAP = 5.5  # visual establishing shot into a new set (matches main.gd)

# Each skit is tagged with a "scene" so this exercises the multi-set flow and the
# establishing-shot transitions. Lines are (audio_file, actor, ends_with_laugh),
# built from clips already in ./audio (actors alternate for camera variety). Skits
# hop apartment -> coffee_shop -> grocery so both transitions fire.
SKITS = [
	{"scene": "apartment", "lines": [
		("skit_6_line_0.mp3", "A", False),
		("skit_6_line_1.mp3", "B", False),
		("skit_6_line_2.mp3", "A", False),
		("skit_6_line_3.mp3", "B", True),
	]},
	{"scene": "coffee_shop", "lines": [
		("skit_7_line_0.mp3", "A", False),
		("skit_7_line_1.mp3", "B", False),
		("skit_7_line_2.mp3", "A", True),
	]},
	{"scene": "grocery", "lines": [
		("skit_8_line_0.mp3", "B", False),
		("skit_8_line_1.mp3", "K", False),  # Kessler crashes the aisle (grocery-only neighbor)
		("skit_8_line_2.mp3", "A", True),
	]},
]


async def send(payload: dict) -> None:
	# One connection per message, mirroring orchestrator.py.
	async with websockets.connect(GODOT_WS_URL) as ws:
		await ws.send(json.dumps(payload))
		await asyncio.sleep(SEND_HOLD)  # hold so Godot can poll the packet


async def wait(seconds: float) -> None:
	# `send` already consumed SEND_HOLD of the clip's playtime.
	await asyncio.sleep(max(0.0, seconds - SEND_HOLD))


async def main() -> None:
	print(f"=== WS smoke test -> {GODOT_WS_URL} (make sure Godot is playing) ===")
	current_scene = "apartment"  # Godot starts in the apartment
	try:
		for i, skit in enumerate(SKITS, start=1):
			scene = skit.get("scene", "apartment")
			# Act break before each skit: establishing shot if the location changed,
			# otherwise a plain stinger (and nothing before the very first skit).
			if scene != current_scene:
				print(f"  ~ establishing shot -> {scene} ~")
				await send({"event": "set_scene", "scene": scene})
				await wait(SCENE_TRANSITION_GAP)
				current_scene = scene
			elif i > 1:
				print("  ~ stinger ~")
				await send({"event": "play_stinger"})
				await wait(STINGER_GAP)

			print(f"--- Skit {i} [{scene}] ---")
			for file_name, actor, ends_with_laugh in skit["lines"]:
				dur = mp3_duration(os.path.join(AUDIO_DIR, file_name), default=4.5)
				print(f"  [Actor {actor}] {file_name} ({dur:.1f}s)")
				await send({"event": "play_audio", "file": file_name, "actor": actor})
				await wait(dur + LINE_PAUSE)
				if ends_with_laugh:
					print("  ~ laugh ~")
					await send({"event": "trigger_laugh"})
					await wait(LAUGH_WAIT + POST_LAUGH_PAUSE)
	except Exception as e:
		print(f"[Error] Could not reach Godot WebSocket: {e}")
		print("        Is the scene running? (Press Play in Godot first.)")
		return
	print("=== Done ===")


if __name__ == "__main__":
	asyncio.run(main())
