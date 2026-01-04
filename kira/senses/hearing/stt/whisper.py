"""
Faster-Whisper STT implementation for Kira hearing sense.

This is the default STT that ships with Kira. It uses faster-whisper
(CTranslate2) for 4-10x speedup over original Whisper.

To swap this for a different STT, create a new module that exports
a class with the same interface as FastWhisperTranscriber.
"""

import sys
import numpy as np
import threading
import queue
import time
from dataclasses import dataclass
from typing import Optional, Callable

from .vad import SileroVAD, SpeechSegment, SAMPLE_RATE, CHUNK_SAMPLES

_model = None
_model_lock = threading.Lock()


def get_model(model_size: str = "base"):
    """Lazy load faster-whisper model."""
    global _model
    if _model is None:
        with _model_lock:
            if _model is None:
                print(f"Loading faster-whisper {model_size}...", file=sys.stderr)
                from faster_whisper import WhisperModel

                _model = WhisperModel(model_size, device="cpu", compute_type="int8")
                print(f"faster-whisper {model_size} loaded", file=sys.stderr)
    return _model


@dataclass
class TranscriptionResult:
    text: str
    language: str
    confidence: float
    duration_ms: int


HALLUCINATION_PATTERNS = [
    "thank you for watching",
    "thanks for watching",
    "please subscribe",
    "like and subscribe",
    "see you next time",
    "bye bye",
    "goodbye",
    "[music]",
    "[applause]",
    "you",
    "the",
]


def is_hallucination(text: str) -> bool:
    """Detect common Whisper hallucinations."""
    import re

    text = text.strip().lower()

    if len(text) < 3:
        return True

    if re.match(r"^[\s\.\,\!\?\-]+$", text):
        return True

    for pattern in HALLUCINATION_PATTERNS:
        if text == pattern:
            return True
        if len(pattern) > 5 and pattern in text:
            return True

    if re.search(r"\b(\w+)(?:\s+\1){2,}\b", text):
        return True

    if re.match(r"^(\w)(?:\s+\1)+\s*$", text):
        return True

    if re.search(r"(.{1,3})\1{3,}", text):
        return True

    return False


class FastWhisperTranscriber:
    """
    Fast speech transcription using faster-whisper + Silero VAD.

    Target: <500ms per utterance.
    """

    INTERRUPT_KEYWORDS = ["kira", "stop", "wait", "quiet"]

    def __init__(
        self,
        model_size: str = "base",
        vad_threshold: float = 0.5,
        on_transcription: Optional[Callable[[TranscriptionResult], None]] = None,
        on_interrupt: Optional[Callable[[str], None]] = None,
    ):
        self.model_size = model_size
        self.on_transcription = on_transcription
        self.on_interrupt = on_interrupt

        self.vad = SileroVAD(
            threshold=vad_threshold,
            min_speech_ms=250,
            min_silence_ms=700,
            on_speech_segment=self._handle_speech,
        )

        self._model = None
        self._running = False
        self._audio_queue = queue.Queue()
        self._muted = False
        self._mute_lock = threading.Lock()

    def _get_model(self):
        if self._model is None:
            self._model = get_model(self.model_size)
        return self._model

    def _handle_speech(self, segment: SpeechSegment):
        """Process a speech segment."""
        try:
            with self._mute_lock:
                is_muted = self._muted

            model = self._get_model()

            t0 = time.time()
            segments, info = model.transcribe(
                segment.audio,
                language="en",
                beam_size=1,
                best_of=1,
                vad_filter=False,
            )

            text_parts = []
            for seg in segments:
                text_parts.append(seg.text)

            text = " ".join(text_parts).strip()
            inference_ms = int((time.time() - t0) * 1000)

            if not text:
                return

            if is_hallucination(text):
                print(f"Filtered hallucination: '{text[:50]}'", file=sys.stderr)
                return

            is_interrupt = self._is_interrupt(text)
            if is_interrupt and self.on_interrupt:
                try:
                    self.on_interrupt(text)
                except Exception as e:
                    print(f"Interrupt callback error: {e}", file=sys.stderr)

            if is_muted:
                return

            result = TranscriptionResult(
                text=text,
                language=info.language or "en",
                confidence=1.0,
                duration_ms=inference_ms,
            )

            if self.on_transcription:
                try:
                    self.on_transcription(result)
                except Exception as e:
                    print(f"Transcription callback error: {e}", file=sys.stderr)

        except Exception as e:
            print(f"Speech handling error: {e}", file=sys.stderr)

    def _is_interrupt(self, text: str) -> bool:
        """Check if text contains interrupt keyword."""
        text_lower = text.lower()
        return any(kw in text_lower for kw in self.INTERRUPT_KEYWORDS)

    def mute(self):
        """Mute transcriptions (still detect interrupts)."""
        with self._mute_lock:
            self._muted = True
        self.vad.reset()

    def unmute(self):
        """Resume transcriptions."""
        self.vad.reset()
        with self._mute_lock:
            self._muted = False

    def start(self) -> bool:
        """Start the transcriber."""
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
                callback=audio_callback,
            )
            self._stream.start()

            self._process_thread = threading.Thread(
                target=self._process_loop, daemon=True
            )
            self._process_thread.start()

            print("Fast Whisper transcriber started", file=sys.stderr)
            return True

        except Exception as e:
            print(f"Transcriber start error: {e}", file=sys.stderr)
            self._running = False
            return False

    def stop(self):
        """Stop the transcriber."""
        self._running = False
        if hasattr(self, "_stream"):
            self._stream.stop()
            self._stream.close()

    def _process_loop(self):
        """Main processing loop."""
        while self._running:
            try:
                audio_chunk = self._audio_queue.get(timeout=0.1)
                with self._mute_lock:
                    if self._muted:
                        continue
                self.vad.process_chunk(audio_chunk)
            except queue.Empty:
                continue
            except Exception as e:
                print(f"Process loop error: {e}", file=sys.stderr)
