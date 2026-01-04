"""
Fast TTS Service using Piper.

Piper is ~50x real-time on CPU, generating 3+ seconds of audio in <100ms.
This is 30-50x faster than Chatterbox.
"""

import sys
import os
import subprocess
import tempfile
import threading
import queue
from pathlib import Path
from typing import Optional

# Default voice model path
DEFAULT_VOICE_PATH = os.path.expanduser("~/.local/share/piper-voices/en_US-amy-medium.onnx")

# Lazy load
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
                print(f"Piper loaded (sample rate: {_voice.config.sample_rate}Hz)", file=sys.stderr)
    return _voice


class PiperTTS:
    """
    Fast text-to-speech using Piper.
    
    Target: <100ms generation for typical sentences (vs 2-5s with Chatterbox).
    """
    
    def __init__(self, voice_path: str = DEFAULT_VOICE_PATH):
        self.voice_path = voice_path
        self._audio_queue = queue.Queue()
        self._playback_thread = None
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
        
        # Generate audio
        audio_bytes = b''
        sample_rate = None
        for chunk in voice.synthesize(text):
            audio_bytes += chunk.audio_int16_bytes
            sample_rate = chunk.sample_rate
        
        if not audio_bytes:
            return None
        
        # Save to temp file
        with tempfile.NamedTemporaryFile(suffix='.wav', delete=False) as f:
            # Write WAV header + data
            import wave
            with wave.open(f.name, 'wb') as wav:
                wav.setnchannels(1)
                wav.setsampwidth(2)  # 16-bit
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
                except:
                    try:
                        self._playback_process.kill()
                    except:
                        pass
        
        # Clear queue
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
            # macOS: use afplay
            self._playback_process = subprocess.Popen(
                ['afplay', path],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL
            )
        
        try:
            self._playback_process.wait()
        except:
            pass
        finally:
            with self._playback_lock:
                self._playback_process = None
    
    def _ensure_playback_thread(self):
        """Ensure background playback thread is running."""
        if self._playback_thread is None or not self._playback_thread.is_alive():
            self._playback_thread = threading.Thread(target=self._playback_loop, daemon=True)
            self._playback_thread.start()
    
    def _playback_loop(self):
        """Background thread for non-blocking playback."""
        while True:
            try:
                audio_path = self._audio_queue.get(timeout=1.0)
                if not self._interrupted:
                    self._play_audio(audio_path)
                # Clean up temp file
                try:
                    os.unlink(audio_path)
                except:
                    pass
            except queue.Empty:
                continue
            except Exception as e:
                print(f"Playback error: {e}", file=sys.stderr)


if __name__ == '__main__':
    import time
    
    print("Testing Piper TTS...")
    print("-" * 40)
    
    tts = PiperTTS()
    
    test_texts = [
        "Hello!",
        "I am Kira, your visual AI companion.",
        "All systems are operational. I can see, hear, and speak.",
    ]
    
    for text in test_texts:
        print(f"\nGenerating: '{text}'")
        t0 = time.time()
        tts.speak(text, blocking=True)
        elapsed = (time.time() - t0) * 1000
        print(f"Total time (generate + play): {elapsed:.0f}ms")
    
    print("\nDone!")
