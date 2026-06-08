#!/usr/bin/env python3
"""
Whisper voice transcription — standalone mode.

Records from microphone until you press Enter, then transcribes via
OpenAI Whisper and pastes the result into whatever is focused on screen.

Use this if you prefer not to run a background daemon. The trade-off:
you need a terminal window open, and there is a 2–3 second startup delay
before recording begins (loading Python and audio libraries each time).

For instant recording with a keyboard shortcut and no terminal window,
use the daemon mode instead (whisper_daemon.py + whisper_trigger.sh).

Usage:
    python3 transcribe.py        # default language (Swedish)
    python3 transcribe.py sv     # Swedish explicitly
    python3 transcribe.py en     # English

Requirements:
    pip install openai sounddevice numpy
    brew install ffmpeg
    OPENAI_API_KEY must be set in environment (add to ~/.zshrc)
"""

import os
import sys
import subprocess
import threading
import datetime
import numpy as np
import sounddevice as sd
from pathlib import Path
from openai import OpenAI

# ── Config ────────────────────────────────────────────────────────────────────
SAMPLE_RATE    = 16000
MP3_BITRATE    = "64k"
CHUNK_MINUTES  = 20
RECORDINGS_DIR = Path.home() / "recordings"
LANGUAGE_LABELS = {"sv": "Swedish 🇸🇪", "en": "English 🇬🇧"}
DEFAULT_LANGUAGE = "sv"

# Preferred input devices in priority order — avoids triggering Bluetooth
# headphone profile switches (which add 5+ seconds of startup delay).
# Edit this list to match your hardware, or set to [] to use system default.
# Run: python3 -c "import sounddevice as sd; print(sd.query_devices())"
PREFERRED_INPUT_DEVICES = ["MacBook Pro"]
# ─────────────────────────────────────────────────────────────────────────────

LANGUAGE = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_LANGUAGE


def find_input_device() -> int | None:
    """Return device index for the first preferred mic found, else None (system default)."""
    devices = sd.query_devices()
    for preferred in PREFERRED_INPUT_DEVICES:
        for i, d in enumerate(devices):
            if d["max_input_channels"] > 0 and preferred.lower() in d["name"].lower():
                return i
    return None


def record_until_enter() -> np.ndarray:
    """Record audio from microphone until user presses Enter."""
    label = LANGUAGE_LABELS.get(LANGUAGE, LANGUAGE)

    device = find_input_device()
    device_name = (
        sd.query_devices(device)["name"]
        if device is not None
        else sd.query_devices(sd.default.device[0])["name"]
    )
    print(f"🎙  Recording [{label}] via {device_name}... (press Enter to stop)")

    frames = []
    stop_event = threading.Event()

    def callback(indata, frame_count, time_info, status):
        if not stop_event.is_set():
            frames.append(indata.copy())

    with sd.InputStream(samplerate=SAMPLE_RATE, channels=1,
                        dtype="float32", callback=callback, device=device):
        input()
        stop_event.set()

    if not frames:
        print("No audio recorded.")
        sys.exit(1)

    return np.concatenate(frames, axis=0).flatten()


def save_wav(audio: np.ndarray, path: Path):
    import wave
    pcm = (audio * 32767).astype(np.int16)
    with wave.open(str(path), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(SAMPLE_RATE)
        wf.writeframes(pcm.tobytes())


def wav_to_mp3(wav_path: Path, mp3_path: Path):
    result = subprocess.run(
        ["ffmpeg", "-y", "-i", str(wav_path),
         "-codec:a", "libmp3lame", "-b:a", MP3_BITRATE, str(mp3_path)],
        capture_output=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"ffmpeg failed:\n{result.stderr.decode()}")


def transcribe_file(path: Path) -> str:
    client = OpenAI()
    with open(path, "rb") as f:
        result = client.audio.transcriptions.create(
            model="whisper-1",
            file=f,
            language=LANGUAGE,
        )
    return result.text.strip()


def transcribe_audio(audio: np.ndarray, wav_path: Path) -> str:
    duration_min = len(audio) / SAMPLE_RATE / 60
    chunk_samples = int(CHUNK_MINUTES * 60 * SAMPLE_RATE)
    chunks = [audio[i:i + chunk_samples]
              for i in range(0, len(audio), chunk_samples)]

    n = len(chunks)
    print(f"   Duration: {duration_min:.1f} min"
          + (f" — splitting into {n} chunks" if n > 1 else ""))

    transcripts = []
    for idx, chunk in enumerate(chunks):
        label = f"chunk {idx + 1}/{n}" if n > 1 else "audio"
        print(f"⏳  Transcribing {label}...")

        if n > 1:
            chunk_wav = wav_path.with_suffix(f".part{idx}.wav")
            save_wav(chunk, chunk_wav)
        else:
            chunk_wav = wav_path

        mp3_path = wav_path.with_suffix(f".part{idx}.mp3" if n > 1 else ".mp3")

        try:
            wav_to_mp3(chunk_wav, mp3_path)
            transcripts.append(transcribe_file(mp3_path))
        finally:
            mp3_path.unlink(missing_ok=True)
            if n > 1:
                chunk_wav.unlink(missing_ok=True)

    return " ".join(transcripts)


def paste_to_focused(text: str):
    """Copy text to clipboard and paste into whatever is currently focused."""
    subprocess.run(["pbcopy"], input=text.encode("utf-8"), check=True)
    subprocess.run([
        "osascript", "-e",
        'tell application "System Events" to keystroke "v" using command down'
    ], check=True)


def main():
    api_key = os.environ.get("OPENAI_API_KEY")
    if not api_key:
        print("❌  OPENAI_API_KEY not set.")
        print("    Add this to your ~/.zshrc:")
        print('    export OPENAI_API_KEY="sk-..."')
        sys.exit(1)

    if subprocess.run(["which", "ffmpeg"], capture_output=True).returncode != 0:
        print("❌  ffmpeg not found. Install with: brew install ffmpeg")
        sys.exit(1)

    RECORDINGS_DIR.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    wav_path = RECORDINGS_DIR / f"{timestamp}.wav"

    audio = record_until_enter()

    print(f"💾  Saving to {wav_path}")
    save_wav(audio, wav_path)

    try:
        text = transcribe_audio(audio, wav_path)
    except Exception as e:
        print(f"\n❌  Transcription failed: {e}")
        print(f"    Recording kept at: {wav_path}")
        print(f"    Retry with: python3 {__file__} {LANGUAGE}")
        sys.exit(1)

    print(f"\n📝  Transcript:\n{text}\n")
    paste_to_focused(text)
    print(f"✅  Pasted.  (recording at {wav_path})")


if __name__ == "__main__":
    main()
