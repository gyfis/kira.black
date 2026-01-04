"""
Chatterbox TTS Service for Kira.

Provides local text-to-speech using Chatterbox-Turbo (fast, ~350M params).
Supports voice cloning and interruptable playback.
"""

import sys
import json
import tempfile
import subprocess
import signal
from pathlib import Path
from typing import Optional
import threading
import queue
import os

# Lazy imports for faster startup
_model = None
_model_lock = threading.Lock()
_model_type = None  # 'turbo' or 'standard'


def _load_turbo_model_local(device: str):
    """
    Load Chatterbox-Turbo using local files only (no HF token required).
    
    Falls back to downloading if local files not found.
    """
    from huggingface_hub import snapshot_download
    from chatterbox.tts_turbo import ChatterboxTurboTTS
    
    try:
        # Try loading from local cache first (no auth required)
        local_path = snapshot_download(
            'ResembleAI/chatterbox-turbo',
            local_files_only=True
        )
        return ChatterboxTurboTTS.from_local(local_path, device)
    except Exception as e:
        # If not cached locally, fall back to regular download (requires HF_TOKEN)
        print(f"Local cache miss, trying download: {e}", file=sys.stderr)
        return ChatterboxTurboTTS.from_pretrained(device=device)


def get_model(prefer_turbo: bool = True):
    """
    Lazy load the Chatterbox model.
    
    Args:
        prefer_turbo: If True, try to load Turbo model first (faster).
    """
    global _model, _model_type
    if _model is None:
        with _model_lock:
            if _model is None:
                import torch
                device = "mps" if torch.backends.mps.is_available() else "cpu"
                
                if prefer_turbo:
                    try:
                        print("Loading Chatterbox-Turbo model...", file=sys.stderr)
                        _model = _load_turbo_model_local(device)
                        _model_type = 'turbo'
                        print(f"Chatterbox-Turbo loaded on {device}", file=sys.stderr)
                    except Exception as e:
                        print(f"Turbo model failed ({e}), falling back to standard...", file=sys.stderr)
                        prefer_turbo = False
                
                if not prefer_turbo or _model is None:
                    print("Loading Chatterbox model...", file=sys.stderr)
                    from chatterbox.tts import ChatterboxTTS as _ChatterboxTTS
                    _model = _ChatterboxTTS.from_pretrained(device=device)
                    _model_type = 'standard'
                    print(f"Chatterbox loaded on {device}", file=sys.stderr)
    
    return _model


class ChatterboxTTS:
    """
    Text-to-speech using Chatterbox with interruptable playback.
    
    Supports:
    - Voice cloning from reference audio
    - Non-blocking playback with interrupt capability
    - Queue-based playback for multiple utterances
    """
    
    def __init__(self, voice_ref_path: Optional[str] = None, prefer_turbo: bool = True):
        self.voice_ref_path = voice_ref_path
        self.prefer_turbo = prefer_turbo
        self._audio_queue = queue.Queue()
        self._playback_thread = None
        self._playback_process: Optional[subprocess.Popen] = None
        self._playback_lock = threading.Lock()
        self._interrupted = False
        
    def speak(self, text: str, blocking: bool = True, timeout: float = 30.0) -> Optional[str]:
        """
        Convert text to speech and play it.
        
        Args:
            text: Text to speak
            blocking: If True, wait for audio to finish playing
            timeout: Maximum time for generation in seconds
            
        Returns:
            Path to generated audio file (if not blocking), None on error.
        """
        if not text or not text.strip():
            return None
        
        # Limit text length to avoid very long generation times
        max_chars = 500
        if len(text) > max_chars:
            print(f"Text truncated from {len(text)} to {max_chars} chars", file=sys.stderr)
            text = text[:max_chars] + "..."
        
        try:
            self._interrupted = False
            model = get_model(self.prefer_turbo)
            
            # Generate audio
            import torchaudio as ta
            
            if self.voice_ref_path and Path(self.voice_ref_path).exists():
                wav = model.generate(text, audio_prompt_path=self.voice_ref_path)
            else:
                wav = model.generate(text)
            
            # Save to temp file
            with tempfile.NamedTemporaryFile(suffix='.wav', delete=False) as f:
                ta.save(f.name, wav, model.sr)
                audio_path = f.name
            
            if blocking:
                self._play_audio(audio_path)
                return None
            else:
                self._audio_queue.put(audio_path)
                self._ensure_playback_thread()
                return audio_path
                
        except Exception as e:
            print(f"TTS generation error: {e}", file=sys.stderr)
            return None
    
    def interrupt(self):
        """
        Interrupt current playback immediately.
        
        Stops any currently playing audio and clears the queue.
        """
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
        
        print("TTS interrupted", file=sys.stderr)
    
    def is_speaking(self) -> bool:
        """Check if currently speaking."""
        with self._playback_lock:
            if self._playback_process and self._playback_process.poll() is None:
                return True
        return not self._audio_queue.empty()
    
    def _play_audio(self, path: str):
        """Play audio file using system command."""
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
        """Background thread for non-blocking audio playback."""
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


def run_service():
    """Run as a simple stdin/stdout service."""
    tts = ChatterboxTTS()
    
    print(json.dumps({'type': 'ready'}), flush=True)
    
    for line in sys.stdin:
        try:
            request = json.loads(line.strip())
            
            if request.get('command') == 'interrupt':
                tts.interrupt()
                print(json.dumps({'status': 'interrupted'}), flush=True)
                continue
            
            if request.get('command') == 'status':
                print(json.dumps({
                    'status': 'ok',
                    'speaking': tts.is_speaking()
                }), flush=True)
                continue
            
            text = request.get('text', '')
            blocking = request.get('blocking', True)
            
            result = tts.speak(text, blocking=blocking)
            
            response = {'status': 'ok'}
            if result:
                response['audio_path'] = result
                
            print(json.dumps(response), flush=True)
            
        except json.JSONDecodeError as e:
            print(json.dumps({'status': 'error', 'message': str(e)}), flush=True)
        except Exception as e:
            print(json.dumps({'status': 'error', 'message': str(e)}), flush=True)


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--test':
        # Quick test mode
        tts = ChatterboxTTS()
        print("Generating speech...")
        tts.speak("Hello! I am Kira, your visual AI companion.")
        print("Done!")
    elif len(sys.argv) > 1 and sys.argv[1] == '--interrupt-test':
        import time
        
        tts = ChatterboxTTS()
        
        print("Starting long speech (interrupt with Ctrl+C)...")
        
        def speak_async():
            tts.speak(
                "This is a test of the interrupt functionality. "
                "I will keep talking for a while so you can test interrupting me. "
                "Feel free to press Control C at any time to stop me mid sentence. "
                "The interrupt should stop playback immediately.",
                blocking=True
            )
        
        thread = threading.Thread(target=speak_async)
        thread.start()
        
        time.sleep(2)  # Let it start
        
        try:
            while thread.is_alive():
                time.sleep(0.1)
        except KeyboardInterrupt:
            print("\nInterrupting...")
            tts.interrupt()
            thread.join(timeout=1)
            print("Interrupted!")
    else:
        run_service()
