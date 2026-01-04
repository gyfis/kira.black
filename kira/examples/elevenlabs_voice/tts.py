"""
ElevenLabs TTS implementation for Kira.

This example shows how to swap the default Piper TTS for ElevenLabs
cloud-based TTS with high-quality voices.

To use this:
1. pip install elevenlabs
2. Set ELEVENLABS_API_KEY environment variable
3. Replace the import in voice/output.py:
   - from tts.piper import PiperTTS
   + from examples.elevenlabs_voice.tts import ElevenLabsTTS as PiperTTS

Or create a new voice output that uses this TTS directly.
"""

import os
import sys
import tempfile
import subprocess
import threading
import queue
from typing import Optional


class ElevenLabsTTS:
    """
    High-quality cloud TTS using ElevenLabs API.

    Same interface as PiperTTS so it's a drop-in replacement.

    Tradeoffs vs Piper:
    - Pro: Much higher quality, more natural voices
    - Pro: Many voice options and voice cloning
    - Con: Requires internet connection
    - Con: API costs (free tier has limits)
    - Con: Higher latency (~500ms vs ~50ms)
    """

    # Default to a good conversational voice
    DEFAULT_VOICE = "Rachel"  # Or use voice_id for custom voices

    def __init__(self, voice: str = DEFAULT_VOICE, api_key: Optional[str] = None):
        self.voice = voice
        self.api_key = api_key or os.environ.get("ELEVENLABS_API_KEY")

        if not self.api_key:
            raise ValueError(
                "ElevenLabs API key required. Set ELEVENLABS_API_KEY env var "
                "or pass api_key parameter."
            )

        self._client = None
        self._audio_queue: queue.Queue = queue.Queue()
        self._playback_thread: Optional[threading.Thread] = None
        self._playback_process: Optional[subprocess.Popen] = None
        self._playback_lock = threading.Lock()
        self._interrupted = False

    def _get_client(self):
        """Lazy-load ElevenLabs client."""
        if self._client is None:
            try:
                from elevenlabs.client import ElevenLabs

                self._client = ElevenLabs(api_key=self.api_key)
            except ImportError:
                raise ImportError(
                    "elevenlabs package not installed. Run: pip install elevenlabs"
                )
        return self._client

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

        try:
            client = self._get_client()

            # Generate audio
            audio = client.generate(
                text=text,
                voice=self.voice,
                model="eleven_turbo_v2",  # Faster model, good for real-time
            )

            # Save to temp file
            with tempfile.NamedTemporaryFile(suffix=".mp3", delete=False) as f:
                for chunk in audio:
                    f.write(chunk)
                audio_path = f.name

            if blocking:
                self._play_audio(audio_path)
                return None
            else:
                self._audio_queue.put(audio_path)
                self._ensure_playback_thread()
                return audio_path

        except Exception as e:
            print(f"ElevenLabs TTS error: {e}", file=sys.stderr)
            return None

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

        # Clear queue
        while not self._audio_queue.empty():
            try:
                self._audio_queue.get_nowait()
            except queue.Empty:
                break

        print("ElevenLabs TTS interrupted", file=sys.stderr)

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
            # macOS: use afplay (works with mp3)
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
            # Clean up temp file
            try:
                os.unlink(path)
            except Exception:
                pass

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
            except queue.Empty:
                continue
            except Exception as e:
                print(f"Playback error: {e}", file=sys.stderr)


# Quick test
if __name__ == "__main__":
    print("Testing ElevenLabs TTS...")
    print("Make sure ELEVENLABS_API_KEY is set")
    print("-" * 40)

    tts = ElevenLabsTTS()
    tts.speak("Hello! I am Kira, speaking through ElevenLabs.", blocking=True)
    print("Done!")
