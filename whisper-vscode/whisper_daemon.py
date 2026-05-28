#!/usr/bin/env python3
"""
Whisper daemon — loads heavy imports once at startup, then responds to
toggle commands over a Unix socket. Start once at login via LaunchAgent.
Trigger with: whisper_trigger.sh en  (or sv)
"""

import os
import re
import sys
import json
import wave
import socket
import threading
import subprocess
import datetime
import numpy as np
import sounddevice as sd
from pathlib import Path
from openai import OpenAI

# ── Config ────────────────────────────────────────────────────────────────────
SAMPLE_RATE     = 16000
MP3_BITRATE     = "64k"
CHUNK_MINUTES   = 20
RECORDINGS_DIR  = Path.home() / "recordings"
SOCKET_PATH     = "/tmp/whisper_daemon.sock"
LANGUAGE_LABELS = {"sv": "Swedish", "en": "English"}
PREFERRED_INPUT_DEVICES = ["Logitech Webcam C925e", "MacBook Pro"]
TRANSCRIPT_FILE = "/tmp/whisper_latest_transcript.txt"
# ─────────────────────────────────────────────────────────────────────────────


def log(msg):
    ts = datetime.datetime.now().strftime("%H:%M:%S")
    print(f"[{ts}] {msg}", flush=True)


def load_api_key():
    key = os.environ.get("OPENAI_API_KEY")
    if key:
        return key
    zshrc = Path.home() / ".zshrc"
    if zshrc.exists():
        m = re.search(r'OPENAI_API_KEY=["\']?([^\s"\']+)', zshrc.read_text())
        if m:
            return m.group(1)
    return None


def find_input_device():
    devices = sd.query_devices()
    for preferred in PREFERRED_INPUT_DEVICES:
        for i, d in enumerate(devices):
            if d["max_input_channels"] > 0 and preferred.lower() in d["name"].lower():
                return i
    return None


def notify(title, message):
    subprocess.run(
        ["osascript", "-e", f'display notification "{message}" with title "{title}"'],
        capture_output=True,
    )


def save_wav(audio: np.ndarray, path: Path):
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
        raise RuntimeError(f"ffmpeg failed: {result.stderr.decode()}")


def transcribe_file(path: Path, lang: str, client: OpenAI) -> str:
    with open(path, "rb") as f:
        result = client.audio.transcriptions.create(
            model="whisper-1", file=f, language=lang,
        )
    return result.text.strip()


def paste_text(text: str):
    subprocess.run(["pbcopy"], input=text.encode("utf-8"), check=True)
    subprocess.run(
        ["osascript", "-e",
         'tell application "System Events" to keystroke "v" using command down'],
        check=True,
    )


class WhisperDaemon:
    def __init__(self):
        self.lock = threading.Lock()
        self.status = "idle"
        self.frames: list = []
        self.stop_event = threading.Event()
        self.lang = "sv"

        api_key = load_api_key()
        if not api_key:
            log("ERROR: OPENAI_API_KEY not found in env or ~/.zshrc")
            sys.exit(1)
        os.environ["OPENAI_API_KEY"] = api_key

        self.device = find_input_device()
        device_name = (
            sd.query_devices(self.device)["name"]
            if self.device is not None
            else sd.query_devices(sd.default.device[0])["name"]
        )
        log(f"Ready. Input device: {device_name}")
        notify("Whisper Daemon", f"Ready — {device_name.split('(')[0].strip()}")

    # ── Public API ────────────────────────────────────────────────────────────

    def toggle(self, lang: str) -> str:
        with self.lock:
            if self.status == "idle":
                self.lang = lang
                self.status = "recording"
                self.stop_event.clear()
                self.frames = []
                threading.Thread(target=self._record_and_transcribe, daemon=True).start()
                return "recording_started"
            elif self.status == "recording":
                self.stop_event.set()
                return "stop_signaled"
            else:
                return "busy"

    def get_status(self) -> str:
        with self.lock:
            return self.status

    # ── Internal ──────────────────────────────────────────────────────────────

    def _record_and_transcribe(self):
        label = LANGUAGE_LABELS.get(self.lang, self.lang)
        device_name = (
            sd.query_devices(self.device)["name"].split("(")[0].strip()
            if self.device is not None else "default mic"
        )
        try:
            log(f"Recording [{label}] via {device_name}")
            notify("Whisper", f"🎙 Recording [{label}] — press shortcut again to stop")

            def callback(indata, frame_count, time_info, status):
                if not self.stop_event.is_set():
                    self.frames.append(indata.copy())

            with sd.InputStream(samplerate=SAMPLE_RATE, channels=1,
                                dtype="float32", device=self.device,
                                callback=callback):
                self.stop_event.wait()

            if not self.frames:
                log("No audio captured — recording too short, skipping.")
                notify("Whisper", "Recording too short — nothing to transcribe.")
                return

            audio = np.concatenate(self.frames).flatten()
            duration = len(audio) / SAMPLE_RATE
            log(f"Stopped ({duration:.1f}s). Transcribing…")

            with self.lock:
                self.status = "transcribing"
            notify("Whisper", "⏳ Transcribing…")

            RECORDINGS_DIR.mkdir(parents=True, exist_ok=True)
            ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
            wav_path = RECORDINGS_DIR / f"{ts}.wav"
            save_wav(audio, wav_path)

            client = OpenAI()
            text = self._transcribe_audio(audio, wav_path, client)
            log(f"Transcript: {text[:100]}{'…' if len(text) > 100 else ''}")
            # Write transcript for trigger script to pick up and paste
            # (paste happens in VS Code terminal context which has accessibility)
            Path(TRANSCRIPT_FILE).write_text(text, encoding="utf-8")

        except Exception as e:
            log(f"Error in recording/transcription: {e}")
            notify("Whisper ❌", str(e)[:120])
        finally:
            with self.lock:
                self.status = "idle"

    def _transcribe_audio(self, audio: np.ndarray, wav_path: Path,
                          client: OpenAI) -> str:
        chunk_samples = int(CHUNK_MINUTES * 60 * SAMPLE_RATE)
        chunks = [audio[i:i + chunk_samples]
                  for i in range(0, len(audio), chunk_samples)]
        transcripts = []
        for idx, chunk in enumerate(chunks):
            is_multi = len(chunks) > 1
            chunk_wav = wav_path.with_suffix(f".part{idx}.wav") if is_multi else wav_path
            if is_multi:
                save_wav(chunk, chunk_wav)
            mp3_path = chunk_wav.with_suffix(".mp3")
            try:
                wav_to_mp3(chunk_wav, mp3_path)
                transcripts.append(transcribe_file(mp3_path, self.lang, client))
            finally:
                mp3_path.unlink(missing_ok=True)
                if is_multi:
                    chunk_wav.unlink(missing_ok=True)
        return " ".join(transcripts)

    # ── Socket server ─────────────────────────────────────────────────────────

    def run(self):
        sock_path = Path(SOCKET_PATH)
        if sock_path.exists():
            sock_path.unlink()

        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(SOCKET_PATH)
        server.listen(5)
        log(f"Listening on {SOCKET_PATH}")

        try:
            while True:
                conn, _ = server.accept()
                threading.Thread(
                    target=self._handle_client, args=(conn,), daemon=True
                ).start()
        finally:
            server.close()
            sock_path.unlink(missing_ok=True)

    def _handle_client(self, conn: socket.socket):
        try:
            data = conn.recv(1024).decode().strip()
            msg = json.loads(data)
            action = msg.get("action")
            if action == "toggle":
                result = self.toggle(msg.get("lang", "sv"))
                conn.send(json.dumps({"status": result}).encode())
            elif action == "status":
                conn.send(json.dumps({"status": self.get_status()}).encode())
            else:
                conn.send(json.dumps({"error": "unknown action"}).encode())
        except Exception as e:
            log(f"Client handler error: {e}")
        finally:
            conn.close()


if __name__ == "__main__":
    WhisperDaemon().run()
