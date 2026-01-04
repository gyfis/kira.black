"""
Piper TTS implementation for Kira voice output.

This is the default TTS that ships with Kira. Piper is ~50x real-time
on CPU, generating 3+ seconds of audio in <100ms.

To swap this for a different TTS (e.g., ElevenLabs), create a new module
that exports a class with the same interface as PiperTTS.
"""

import sys
import os
import subprocess
import tempfile
import threading
import queue
from typing import Optional

DEFAULT_VOICE_PATH = os.path.expanduser(
    "~/.local/share/piper-voices/en_US-amy-medium.onnx"
)

_voice = None
_voice_lock = threading.Lock()


def get_voice(model_path: str = DEFAULT_VOICE_PATH):
    """Lazy load Piper voice model."""
    global _voice
    if _voice is None:
        with _voice_lock:
            if _voice is None:
                print(f"Loading Piper voice...", file=sys.stderr)
                from piper import PiperVoice

                _voice = PiperVoice.load(model_path)
                print(
                    f"Piper loaded (sample rate: {_voice.config.sample_rate}Hz)",
                    file=sys.stderr,
                )
    return _voice


class PiperTTS:
    """
    Fast text-to-speech using Piper.

    Target: <100ms generation for typical sentences.
    """

    def __init__(self, voice_path: Optional[str] = None):
        self.voice_path = voice_path or DEFAULT_VOICE_PATH
        self._audio_queue: queue.Queue = queue.Queue()
        self._playback_thread: Optional[threading.Thread] = None
        self._playback_process: Optional[subprocess.Popen] = None
        self._playback_lock = threading.Lock()
        self._interrupted = False

    def speak(self, text: str, blocking: bool = True) -> Optional[str]:
        """
        Convert text to speech and play it.

        Args:
            text: Text to speak
            blocking: If True, wait for audio to finish

        Returns:
            Path to generated audio file (if not blocking)
        """
        if not text or not text.strip():
            return None

        self._interrupted = False
        voice = get_voice(self.voice_path)

        audio_bytes = b""
        sample_rate = 22050  # Default Piper sample rate
        for chunk in voice.synthesize(text):
            audio_bytes += chunk.audio_int16_bytes
            if chunk.sample_rate:
                sample_rate = chunk.sample_rate

        if not audio_bytes:
            return None

        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
            import wave

            with wave.open(f.name, "wb") as wav:
                wav.setnchannels(1)
                wav.setsampwidth(2)
                wav.setframerate(sample_rate)
                wav.writeframes(audio_bytes)
            audio_path = f.name

        if blocking:
            self._play_audio(audio_path)
            return None
        else:
            self._audio_queue.put(audio_path)
            self._ensure_playback_thread()
            return audio_path

    def interrupt(self):
        """Stop current playback immediately."""
        self._interrupted = True

        with self._playback_lock:
            if self._playback_process and self._playback_process.poll() is None:
                try:
                    self._playback_process.terminate()
                    self._playback_process.wait(timeout=0.5)
                except Exception:
                    try:
                        self._playback_process.kill()
                    except Exception:
                        pass

        while not self._audio_queue.empty():
            try:
                self._audio_queue.get_nowait()
            except queue.Empty:
                break

        print("Piper TTS interrupted", file=sys.stderr)

    def is_speaking(self) -> bool:
        """Check if currently speaking."""
        with self._playback_lock:
            if self._playback_process and self._playback_process.poll() is None:
                return True
        return not self._audio_queue.empty()

    def _play_audio(self, path: str):
        """Play audio file."""
        if self._interrupted:
            return

        with self._playback_lock:
            self._playback_process = subprocess.Popen(
                ["afplay", path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
            )

        try:
            self._playback_process.wait()
        except Exception:
            pass
        finally:
            with self._playback_lock:
                self._playback_process = None

    def _ensure_playback_thread(self):
        """Ensure background playback thread is running."""
        if self._playback_thread is None or not self._playback_thread.is_alive():
            self._playback_thread = threading.Thread(
                target=self._playback_loop, daemon=True
            )
            self._playback_thread.start()

    def _playback_loop(self):
        """Background thread for non-blocking playback."""
        while True:
            try:
                audio_path = self._audio_queue.get(timeout=1.0)
                if not self._interrupted:
                    self._play_audio(audio_path)
                try:
                    os.unlink(audio_path)
                except Exception:
                    pass
            except queue.Empty:
                continue
            except Exception as e:
                print(f"Playback error: {e}", file=sys.stderr)
