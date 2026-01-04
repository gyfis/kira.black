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
import time

_vad_model = None
_vad_utils = None
_model_lock = threading.Lock()

SAMPLE_RATE = 16000
CHUNK_MS = 32
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
                    repo_or_dir="snakers4/silero-vad",
                    model="silero_vad",
                    force_reload=False,
                    onnx=True,
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

    Accumulates audio chunks and emits speech segments when silence is detected.
    """

    def __init__(
        self,
        threshold: float = 0.5,
        min_speech_ms: int = 250,
        min_silence_ms: int = 300,
        speech_pad_ms: int = 100,
        on_speech_segment: Optional[Callable[[SpeechSegment], None]] = None,
    ):
        self.threshold = threshold
        self.min_speech_samples = int(SAMPLE_RATE * min_speech_ms / 1000)
        self.min_silence_samples = int(SAMPLE_RATE * min_silence_ms / 1000)
        self.speech_pad_samples = int(SAMPLE_RATE * speech_pad_ms / 1000)
        self.on_speech_segment = on_speech_segment

        self._speech_buffer: List[np.ndarray] = []
        self._silence_samples = 0
        self._speech_samples = 0
        self._in_speech = False
        self._speech_start_time: Optional[float] = None

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

        if len(audio_chunk) < CHUNK_SAMPLES:
            return None

        audio_tensor = torch.from_numpy(audio_chunk[:CHUNK_SAMPLES].astype(np.float32))
        speech_prob = model(audio_tensor, SAMPLE_RATE).item()

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

        else:
            if self._in_speech:
                self._speech_buffer.append(audio_chunk.copy())
                self._silence_samples += len(audio_chunk)

                if self._silence_samples >= self.min_silence_samples:
                    self._emit_segment()

        return speech_prob

    def _emit_segment(self):
        """Emit the current speech segment if valid."""
        if self._speech_samples >= self.min_speech_samples and self._speech_buffer:
            audio = np.concatenate(self._speech_buffer)

            end_time = time.time()
            start_time = self._speech_start_time or end_time

            segment = SpeechSegment(
                audio=audio,
                start_time=start_time,
                end_time=end_time,
                duration_ms=int((end_time - start_time) * 1000),
            )

            if self.on_speech_segment:
                try:
                    self.on_speech_segment(segment)
                except Exception as e:
                    print(f"Speech segment callback error: {e}", file=sys.stderr)

        self.reset()

    def reset(self):
        """Reset state - clears buffer and flags."""
        self._speech_buffer = []
        self._silence_samples = 0
        self._speech_samples = 0
        self._in_speech = False
        self._speech_start_time = None
