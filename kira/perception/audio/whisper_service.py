"""
Whisper STT Service for Kira.

Provides local speech-to-text using Whisper with Silero VAD for efficient processing.
Only runs Whisper on detected speech segments, avoiding wasted inference on silence.
"""

import sys
import json
import numpy as np
import threading
import queue
from dataclasses import dataclass
from typing import Optional, Callable, List
import time
from pathlib import Path

# Handle both direct execution and module import
if __name__ == '__main__':
    sys.path.insert(0, str(Path(__file__).parent.parent))
    from audio.vad import SileroVAD, SpeechSegment, VADTranscriptionPipeline, SAMPLE_RATE, CHUNK_SAMPLES
else:
    from .vad import SileroVAD, SpeechSegment, VADTranscriptionPipeline, SAMPLE_RATE, CHUNK_SAMPLES

# Lazy imports
_model = None
_model_lock = threading.Lock()


def get_model(model_name: str = "base"):
    """Lazy load the Whisper model."""
    global _model
    if _model is None:
        with _model_lock:
            if _model is None:
                print(f"Loading Whisper model ({model_name})...", file=sys.stderr)
                import whisper
                _model = whisper.load_model(model_name)
                print("Whisper loaded", file=sys.stderr)
    return _model


@dataclass
class TranscriptionResult:
    text: str
    language: str
    confidence: float
    duration_ms: int


# Patterns that indicate Whisper hallucinations on silence/noise
HALLUCINATION_PATTERNS = [
    # Repetitive patterns
    r'(.{2,})\1{3,}',  # Same phrase repeated 4+ times
    # Common hallucinations
    'thank you for watching',
    'thanks for watching',
    'please subscribe',
    'like and subscribe',
    'see you next time',
    'bye bye',
    'goodbye',
    '♪',
    '[music]',
    '[applause]',
    '[laughter]',
    '...',
    # Extremely short or empty
]


def is_hallucination(text: str) -> bool:
    """Detect common Whisper hallucinations on silence/noise."""
    import re
    
    text = text.strip().lower()
    
    # Too short
    if len(text) < 2:
        return True
    
    # Just punctuation or special chars
    if re.match(r'^[\s\.\,\!\?\-]+$', text):
        return True
    
    # Check known hallucination phrases
    for pattern in HALLUCINATION_PATTERNS:
        if pattern.startswith('r\''):
            continue  # Skip regex in simple check
        if pattern in text:
            return True
    
    # Check for repetitive patterns using regex
    if re.search(r'(.{2,})\1{3,}', text):
        return True
    
    return False


class WhisperTranscriber:
    """
    Real-time speech transcription using Whisper with Silero VAD.
    
    Uses Silero VAD (~1ms on CPU) to detect speech before running Whisper,
    avoiding expensive inference on silence/background noise.
    """
    
    def __init__(
        self,
        model_name: str = "base",
        vad_threshold: float = 0.5,
        on_transcription: Optional[Callable[[TranscriptionResult], None]] = None
    ):
        self.model_name = model_name
        self.on_transcription = on_transcription
        
        self._pipeline = VADTranscriptionPipeline(
            whisper_model=model_name,
            vad_threshold=vad_threshold,
            on_transcription=self._handle_transcription
        )
        self._running = False
    
    def _handle_transcription(self, result: dict):
        """Convert pipeline result to TranscriptionResult, filtering hallucinations."""
        text = result.get('text', '').strip()
        
        # Filter out hallucinations
        if is_hallucination(text):
            print(f"Filtered hallucination: '{text[:50]}...'", file=sys.stderr)
            return
        
        tr = TranscriptionResult(
            text=text,
            language=result.get('language', 'en'),
            confidence=1.0,
            duration_ms=result.get('duration_ms', 0)
        )
        if self.on_transcription:
            try:
                self.on_transcription(tr)
            except Exception as e:
                print(f"Transcription callback error: {e}", file=sys.stderr)
    
    def start(self):
        """Start the audio capture and transcription."""
        self._running = True
        self._pipeline.start()
        print("Whisper transcriber started (with Silero VAD)", file=sys.stderr)
    
    def stop(self):
        """Stop the transcriber."""
        self._running = False
        self._pipeline.stop()


class InterruptableTranscriber:
    """
    Transcriber that can detect interrupt keywords while listening.
    
    Monitors for keywords like "Kira" or "Stop" that should interrupt
    ongoing TTS playback.
    """
    
    INTERRUPT_KEYWORDS = ['kira', 'stop', 'wait', 'quiet', 'silence', 'hey']
    
    def __init__(
        self,
        model_name: str = "base",
        vad_threshold: float = 0.5,
        on_transcription: Optional[Callable[[TranscriptionResult], None]] = None,
        on_interrupt: Optional[Callable[[str], None]] = None
    ):
        self.model_name = model_name
        self.on_transcription = on_transcription
        self.on_interrupt = on_interrupt
        
        self.vad = SileroVAD(
            threshold=vad_threshold,
            min_speech_ms=200,  # Shorter for interrupt detection
            min_silence_ms=200,
            on_speech_segment=self._handle_speech
        )
        
        self._whisper_model = None
        self._running = False
        self._audio_queue = queue.Queue()
        self._muted = False
        self._mute_lock = threading.Lock()
    
    def _get_whisper(self):
        if self._whisper_model is None:
            self._whisper_model = get_model(self.model_name)
        return self._whisper_model
    
    def _handle_speech(self, segment: SpeechSegment):
        """Process a speech segment - check for interrupts first."""
        try:
            with self._mute_lock:
                if self._muted:
                    # Even when muted, check for interrupt keywords
                    text = self._quick_transcribe(segment.audio)
                    if text and self._is_interrupt(text):
                        if self.on_interrupt:
                            try:
                                self.on_interrupt(text)
                            except Exception as e:
                                print(f"Interrupt callback error: {e}", file=sys.stderr)
                    return
            
            # Full transcription
            model = self._get_whisper()
            t0 = time.time()
            result = model.transcribe(segment.audio, fp16=False)
            inference_ms = int((time.time() - t0) * 1000)
            
            text = result['text'].strip()
            if not text:
                return
            
            # Filter hallucinations
            if is_hallucination(text):
                print(f"Filtered hallucination: '{text[:50]}...'", file=sys.stderr)
                return
            
            # Check for interrupt
            if self._is_interrupt(text):
                if self.on_interrupt:
                    try:
                        self.on_interrupt(text)
                    except Exception as e:
                        print(f"Interrupt callback error: {e}", file=sys.stderr)
                return
            
            # Regular transcription
            tr = TranscriptionResult(
                text=text,
                language=result.get('language', 'en'),
                confidence=1.0,
                duration_ms=inference_ms
            )
            if self.on_transcription:
                try:
                    self.on_transcription(tr)
                except Exception as e:
                    print(f"Transcription callback error: {e}", file=sys.stderr)
        except Exception as e:
            print(f"Speech handling error: {e}", file=sys.stderr)
    
    def _quick_transcribe(self, audio: np.ndarray) -> Optional[str]:
        """Quick transcription for interrupt detection."""
        try:
            model = self._get_whisper()
            result = model.transcribe(audio, fp16=False)
            return result['text'].strip().lower()
        except:
            return None
    
    def _is_interrupt(self, text: str) -> bool:
        """Check if text contains an interrupt keyword."""
        text_lower = text.lower()
        return any(kw in text_lower for kw in self.INTERRUPT_KEYWORDS)
    
    def mute(self):
        """Mute regular transcriptions (still detect interrupts)."""
        with self._mute_lock:
            self._muted = True
    
    def unmute(self):
        """Resume regular transcriptions."""
        with self._mute_lock:
            self._muted = False
    
    def start(self) -> bool:
        """
        Start the transcriber.
        
        Returns:
            True if started successfully, False otherwise.
        """
        try:
            import sounddevice as sd
        except ImportError as e:
            print(f"sounddevice not installed: {e}", file=sys.stderr)
            return False
        
        try:
            self._running = True
            
            def audio_callback(indata, frames, time_info, status):
                if status:
                    print(f"Audio status: {status}", file=sys.stderr)
                self._audio_queue.put(indata.copy().flatten())
            
            self._stream = sd.InputStream(
                samplerate=SAMPLE_RATE,
                channels=1,
                dtype=np.float32,
                blocksize=CHUNK_SAMPLES,
                callback=audio_callback
            )
            self._stream.start()
            
            self._process_thread = threading.Thread(target=self._process_loop, daemon=True)
            self._process_thread.start()
            
            print("Interruptable transcriber started", file=sys.stderr)
            return True
            
        except sd.PortAudioError as e:
            print(f"Audio device error: {e}", file=sys.stderr)
            self._running = False
            return False
        except Exception as e:
            print(f"Transcriber start error: {e}", file=sys.stderr)
            self._running = False
            return False
    
    def stop(self):
        """Stop the transcriber."""
        self._running = False
        if hasattr(self, '_stream'):
            self._stream.stop()
            self._stream.close()
    
    def _process_loop(self):
        """Main processing loop."""
        while self._running:
            try:
                audio_chunk = self._audio_queue.get(timeout=0.1)
                self.vad.process_chunk(audio_chunk)
            except queue.Empty:
                continue
            except Exception as e:
                print(f"Transcriber error: {e}", file=sys.stderr)


# Keep old VoiceActivityDetector for backward compatibility
class VoiceActivityDetector:
    """Simple energy-based voice activity detection (legacy, prefer SileroVAD)."""
    
    SILENCE_THRESHOLD = 0.01
    MAX_SILENCE_DURATION = 1.0
    MIN_SPEECH_DURATION = 0.3
    
    def __init__(self, threshold: float = SILENCE_THRESHOLD):
        self.threshold = threshold
        self.is_speaking = False
        self.speech_start = None
        self.silence_start = None
        
    def process(self, audio_chunk: np.ndarray) -> str:
        energy = np.sqrt(np.mean(audio_chunk.astype(np.float32) ** 2))
        is_speech = energy > self.threshold
        
        if is_speech and not self.is_speaking:
            self.is_speaking = True
            self.speech_start = time.time()
            self.silence_start = None
            return 'speech_start'
        elif is_speech and self.is_speaking:
            self.silence_start = None
            return 'speech'
        elif not is_speech and self.is_speaking:
            if self.silence_start is None:
                self.silence_start = time.time()
            elif time.time() - self.silence_start > self.MAX_SILENCE_DURATION:
                self.is_speaking = False
                duration = time.time() - self.speech_start
                if duration >= self.MIN_SPEECH_DURATION:
                    return 'speech_end'
            return 'speech'
        else:
            return 'silence'


def run_service():
    """Run as a simple service that outputs transcriptions to stdout."""
    transcriber = WhisperTranscriber(model_name="base")
    transcriber.start()
    
    print(json.dumps({'type': 'ready'}), flush=True)
    
    try:
        while True:
            line = sys.stdin.readline()
            if not line:
                break
            
            try:
                cmd = json.loads(line.strip())
                if cmd.get('command') == 'stop':
                    break
            except json.JSONDecodeError:
                pass
                
    except KeyboardInterrupt:
        pass
    finally:
        transcriber.stop()


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--test':
        def on_text(result):
            print(f"Heard: {result.text}")
            
        transcriber = WhisperTranscriber(model_name="base", on_transcription=on_text)
        transcriber.start()
        
        print("Listening for 10 seconds...")
        time.sleep(10)
        transcriber.stop()
    elif len(sys.argv) > 1 and sys.argv[1] == '--interrupt-test':
        def on_text(result):
            print(f"Transcription: {result.text}")
        
        def on_interrupt(text):
            print(f"*** INTERRUPT DETECTED: {text} ***")
        
        transcriber = InterruptableTranscriber(
            model_name="base",
            on_transcription=on_text,
            on_interrupt=on_interrupt
        )
        transcriber.start()
        
        print("Listening for interrupts (say 'Kira' or 'Stop')...")
        print("Press Ctrl+C to exit")
        
        try:
            while True:
                time.sleep(0.1)
        except KeyboardInterrupt:
            print("\nStopping...")
            transcriber.stop()
    else:
        run_service()
