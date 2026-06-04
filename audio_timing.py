"""Tiny dependency-free MP3 duration reader.

Accurate for constant-bitrate MP3 (what edge-tts produces, and what the line
clips in ./audio are). Variable-bitrate files (some stingers) can't be sized
this way, so an implausible result falls back to `default`.
"""

_V1_L3 = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
_V2_L3 = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
_SAMPLE_RATES = {3: [44100, 48000, 32000], 2: [22050, 24000, 16000], 0: [11025, 12000, 8000]}


def mp3_duration(path: str, default: float = 4.0) -> float:
	"""Return clip length in seconds, or `default` on any problem / VBR file."""
	try:
		with open(path, "rb") as fh:
			data = fh.read()
		n = len(data)
		i = 0
		# Skip an ID3v2 tag if present (synchsafe size).
		if data[:3] == b"ID3":
			i = 10 + ((data[6] & 0x7F) << 21 | (data[7] & 0x7F) << 14 | (data[8] & 0x7F) << 7 | (data[9] & 0x7F))
		# Find the first MPEG audio frame header and read its bitrate.
		while i < n - 4:
			if data[i] == 0xFF and (data[i + 1] & 0xE0) == 0xE0:
				ver = (data[i + 1] >> 3) & 3
				layer = (data[i + 1] >> 1) & 3
				br_i = (data[i + 2] >> 4) & 0xF
				sr_i = (data[i + 2] >> 2) & 3
				if layer == 1 and br_i not in (0, 15) and sr_i != 3 and ver in _SAMPLE_RATES:
					bitrate = (_V1_L3[br_i] if ver == 3 else _V2_L3[br_i]) * 1000
					audio_bytes = n - i
					if data[-128:-125] == b"TAG":  # ID3v1 trailer
						audio_bytes -= 128
					dur = audio_bytes * 8 / bitrate
					return dur if 0.1 < dur < 30.0 else default
			i += 1
	except Exception:
		pass
	return default
