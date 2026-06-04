"""Tiny dev helper: send ONE WebSocket event to the running Godot stage.

Usage:
    python send_ev.py set_scene coffee_shop
    python send_ev.py play_audio skit_7_line_0.mp3 A
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
    elif ev == "play_audio":
        payload["file"] = argv[2]
        payload["actor"] = argv[3] if len(argv) > 3 else "A"
    return payload


async def main():
    payload = build_payload(sys.argv)
    async with websockets.connect(GODOT_WS_URL) as ws:
        await ws.send(json.dumps(payload))
        await asyncio.sleep(1.2)
    print(f"sent {payload}")


if __name__ == "__main__":
    asyncio.run(main())
