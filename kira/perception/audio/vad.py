"""
Voice Activity Detection using Silero VAD.

Provides efficient speech detection before running Whisper transcription.
Silero VAD runs on CPU in ~1ms, avoiding wasted Whisper inference on silence.
"""

import sys
import numpy as np
from dataclasses import dataclass
from typing import Optional, Callable, List
import threading
import queue
import time

# Lazy load model
_vad_model = None
_vad_utils = None
_model_lock = threading.Lock()

SAMPLE_RATE = 16000
CHUNK_MS = 32  # Silero works best with 32ms chunks
CHUNK_SAMPLES = int(SAMPLE_RATE * CHUNK_MS / 1000)  # 512 samples


def get_vad_model():
    """Lazy load Silero VAD model."""
    global _vad_model, _vad_utils
    if _vad_model is None:
        with _model_lock:
            if _vad_model is None:
                print("Loading Silero VAD model...", file=sys.stderr)
                import torch
                
                model, utils = torch.hub.load(
                    repo_or_dir='snakers4/silero-vad',
                    model='silero_vad',
                    force_reload=False,
                    onnx=True  # Use ONNX for faster CPU inference
                )
                _vad_model = model
                _vad_utils = utils
                print("Silero VAD loaded (ONNX)", file=sys.stderr)
    return _vad_model, _vad_utils


@dataclass
class SpeechSegment:
    """A detected speech segment."""
    audio: np.ndarray
    start_time: float
    end_time: float
    duration_ms: int


class SileroVAD:
    """
    Voice Activity Detector using Silero VAD.
    
    Accumulates audio chunks and emits speech segments when silence is detected
    after speech, avoiding the need to run Whisper on silence/noise.
    """
    
    def __init__(
        self,
        threshold: float = 0.5,
        min_speech_ms: int = 250,
        min_silence_ms: int = 300,
        speech_pad_ms: int = 100,
        on_speech_segment: Optional[Callable[[SpeechSegment], None]] = None
    ):
        """
        Initialize VAD.
        
        Args:
            threshold: Speech probability threshold (0-1)
            min_speech_ms: Minimum speech duration to consider valid
            min_silence_ms: Silence duration to end a speech segment
            speech_pad_ms: Padding to add before/after speech
            on_speech_segment: Callback when speech segment is complete
        """
        self.threshold = threshold
        self.min_speech_samples = int(SAMPLE_RATE * min_speech_ms / 1000)
        self.min_silence_samples = int(SAMPLE_RATE * min_silence_ms / 1000)
        self.speech_pad_samples = int(SAMPLE_RATE * speech_pad_ms / 1000)
        self.on_speech_segment = on_speech_segment
        
        self._speech_buffer: List[np.ndarray] = []
        self._silence_samples = 0
        self._speech_samples = 0
        self._in_speech = False
        self._speech_start_time = None
        
    def process_chunk(self, audio_chunk: np.ndarray) -> Optional[float]:
        """
        Process an audio chunk through VAD.
        
        Args:
            audio_chunk: Audio samples (float32, 16kHz)
            
        Returns:
            Speech probability (0-1) or None if chunk too small
        """
        import torch
        
        model, _ = get_vad_model()
        
        # Ensure correct shape and type
        if len(audio_chunk) < CHUNK_SAMPLES:
            return None
            
        # Convert to tensor
        audio_tensor = torch.from_numpy(audio_chunk[:CHUNK_SAMPLES].astype(np.float32))
        
        # Get speech probability
        speech_prob = model(audio_tensor, SAMPLE_RATE).item()
        
        # Update state
        is_speech = speech_prob >= self.threshold
        
        if is_speech:
            if not self._in_speech:
                self._in_speech = True
                self._speech_start_time = time.time()
                self._speech_samples = 0
                self._silence_samples = 0
            
            self._speech_buffer.append(audio_chunk.copy())
            self._speech_samples += len(audio_chunk)
            self._silence_samples = 0
            
        else:  # Silence
            if self._in_speech:
                self._speech_buffer.append(audio_chunk.copy())
                self._silence_samples += len(audio_chunk)
                
                # Check if we've had enough silence to end the segment
                if self._silence_samples >= self.min_silence_samples:
                    self._emit_segment()
        
        return speech_prob
    
    def _emit_segment(self):
        """Emit the current speech segment if valid."""
        if self._speech_samples >= self.min_speech_samples and self._speech_buffer:
            # Concatenate all buffered audio
            audio = np.concatenate(self._speech_buffer)
            
            segment = SpeechSegment(
                audio=audio,
                start_time=self._speech_start_time or time.time(),
                end_time=time.time(),
                duration_ms=int(len(audio) / SAMPLE_RATE * 1000)
            )
            
            if self.on_speech_segment:
                self.on_speech_segment(segment)
        
        # Reset state
        self._speech_buffer = []
        self._speech_samples = 0
        self._silence_samples = 0
        self._in_speech = False
        self._speech_start_time = None
    
    def reset(self):
        """Reset VAD state."""
        self._speech_buffer = []
        self._speech_samples = 0
        self._silence_samples = 0
        self._in_speech = False
        self._speech_start_time = None


class VADTranscriptionPipeline:
    """
    Pipeline: Microphone -> VAD -> Speech Segments -> Whisper.
    
    Only runs Whisper on detected speech segments, not continuous audio.
    """
    
    def __init__(
        self,
        whisper_model: str = "base",
        vad_threshold: float = 0.5,
        on_transcription: Optional[Callable] = None
    ):
        self.whisper_model_name = whisper_model
        self._whisper_model = None
        self.on_transcription = on_transcription
        
        self.vad = SileroVAD(
            threshold=vad_threshold,
            on_speech_segment=self._handle_speech_segment
        )
        
        self._running = False
        self._audio_queue = queue.Queue()
        
    def _get_whisper(self):
        """Lazy load Whisper model."""
        if self._whisper_model is None:
            print(f"Loading Whisper {self.whisper_model_name}...", file=sys.stderr)
            import whisper
            self._whisper_model = whisper.load_model(self.whisper_model_name)
            print("Whisper loaded", file=sys.stderr)
        return self._whisper_model
    
    def _handle_speech_segment(self, segment: SpeechSegment):
        """Transcribe a detected speech segment with error handling."""
        try:
            model = self._get_whisper()
            
            t0 = time.time()
            result = model.transcribe(segment.audio, fp16=False)
            inference_ms = int((time.time() - t0) * 1000)
            
            text = result['text'].strip()
            
            if text and self.on_transcription:
                try:
                    self.on_transcription({
                        'text': text,
                        'language': result.get('language', 'en'),
                        'duration_ms': segment.duration_ms,
                        'inference_ms': inference_ms,
                        'start_time': segment.start_time,
                        'end_time': segment.end_time
                    })
                except Exception as e:
                    print(f"Transcription callback error: {e}", file=sys.stderr)
        except Exception as e:
            print(f"Whisper transcription error: {e}", file=sys.stderr)
    
    def start(self) -> bool:
        """
        Start the VAD + transcription pipeline.
        
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
            
            # Start audio stream
            self._stream = sd.InputStream(
                samplerate=SAMPLE_RATE,
                channels=1,
                dtype=np.float32,
                blocksize=CHUNK_SAMPLES,
                callback=audio_callback
            )
            self._stream.start()
            
            # Start processing thread
            self._process_thread = threading.Thread(target=self._process_loop, daemon=True)
            self._process_thread.start()
            
            print("VAD transcription pipeline started", file=sys.stderr)
            return True
            
        except Exception as e:
            print(f"Failed to start VAD pipeline: {e}", file=sys.stderr)
            self._running = False
            return False
    
    def stop(self):
        """Stop the pipeline."""
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
                print(f"VAD error: {e}", file=sys.stderr)


if __name__ == '__main__':
    # Test mode
    def on_text(result):
        print(f"\n[Transcription] {result['text']}")
        print(f"  Duration: {result['duration_ms']}ms, Inference: {result['inference_ms']}ms")
    
    pipeline = VADTranscriptionPipeline(
        whisper_model="base",
        on_transcription=on_text
    )
    
    print("Starting VAD pipeline - speak to test (Ctrl+C to stop)...")
    pipeline.start()
    
    try:
        while True:
            time.sleep(0.1)
    except KeyboardInterrupt:
        print("\nStopping...")
        pipeline.stop()
