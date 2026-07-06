"""Tiny dev helper: send ONE WebSocket event to the running Godot stage.

Usage:
    python send_ev.py set_scene coffee_shop
    python send_ev.py park_cam grocery        # dev: hold a set's exterior cam for a facade still
    python send_ev.py play_audio skit_7_line_0.mp3 A "optional subtitle text"
    python send_ev.py trigger_laugh
    python send_ev.py play_stinger
"""
import asyncio
import json
import sys

import websockets

GODOT_WS_URL = "ws://localhost:9000"


def build_payload(argv):
    ev = argv[1]
    payload = {"event": ev}
    if ev == "set_scene":
        payload["scene"] = argv[2]
    elif ev == "park_cam":
        payload["scene"] = argv[2]
    elif ev == "play_audio":
        payload["file"] = argv[2]
        payload["actor"] = argv[3] if len(argv) > 3 else "A"
        if len(argv) > 4:
            payload["text"] = argv[4]  # shown as an on-screen subtitle
    return payload


async def main():
    payload = build_payload(sys.argv)
    async with websockets.connect(GODOT_WS_URL) as ws:
        await ws.send(json.dumps(payload))
        await asyncio.sleep(1.2)
    print(f"sent {payload}")


if __name__ == "__main__":
    asyncio.run(main())
