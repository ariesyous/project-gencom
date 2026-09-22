"""Prune old baked episodes once shows/ crosses a size budget.

Measured footprint is ~0.65MB/episode, so a small fixed episode count would
throw away content needlessly — this prunes by total size instead, dropping
the oldest episodes (by `aired_at`) until back under budget. Run as the last
step of the bake workflow, in the SAME commit as the new episode + manifest
update, so the manifest and on-disk shows/ directories never disagree.
"""
import json
import os
import shutil

SHOWS_DIR = "./shows"
MANIFEST_PATH = os.path.join(SHOWS_DIR, "manifest.json")
BUDGET_BYTES = 500 * 1024 * 1024  # 500MB soft budget


def _dir_size(path):
	total = 0
	for root, _dirs, files in os.walk(path):
		for f in files:
			fp = os.path.join(root, f)
			if os.path.isfile(fp):
				total += os.path.getsize(fp)
	return total


def prune():
	if not os.path.exists(MANIFEST_PATH):
		return
	with open(MANIFEST_PATH, "r", encoding="utf-8") as fh:
		manifest = json.load(fh)

	episodes = manifest.get("episodes", [])
	episodes.sort(key=lambda e: e.get("aired_at", ""))  # oldest first

	total = _dir_size(SHOWS_DIR)
	removed = []
	i = 0
	while total > BUDGET_BYTES and i < len(episodes):
		ep = episodes[i]
		ep_dir = os.path.join(SHOWS_DIR, ep["id"])
		if os.path.isdir(ep_dir):
			total -= _dir_size(ep_dir)
			shutil.rmtree(ep_dir)
			removed.append(ep["id"])
		i += 1

	if removed:
		manifest["episodes"] = episodes[i:]
		with open(MANIFEST_PATH, "w", encoding="utf-8") as fh:
			json.dump(manifest, fh, indent=2)
		print(f"[Prune] Removed {len(removed)} episode(s): {', '.join(removed)}")
	else:
		print("[Prune] Under budget, nothing removed.")


if __name__ == "__main__":
	prune()
