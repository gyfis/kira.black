"""
Hearing Sense - Microphone-based perception for Kira.

Uses Speech-to-Text (STT) to understand what the user says.
Emits high-priority voice signals that always get a response.
"""

import sys
import os
import threading
from typing import Optional

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from base import BaseSense
from protocol import PRIORITY_VOICE, PRIORITY_INTERRUPT, log


class HearingSense(BaseSense):
    """
    Microphone-based perception using STT.

    Configuration options:
        model_size: Whisper model size (default: "base")
        vad_threshold: VAD sensitivity 0-1 (default: 0.5)
    """

    name = "hearing"
    default_priority = PRIORITY_VOICE

    def __init__(self):
        super().__init__()
        self._transcriber = None
        self._muted = False

        self._config = {
            "model_size": "base",
            "vad_threshold": 0.5,
        }

    def _initialize(self):
        """Load STT model."""
        log(f"[{self.name}] Loading STT model...")
        from stt.whisper import FastWhisperTranscriber

        self._transcriber = FastWhisperTranscriber(
            model_size=self._config["model_size"],
            vad_threshold=self._config["vad_threshold"],
            on_transcription=self._on_transcription,
            on_interrupt=self._on_interrupt,
        )
        log(f"[{self.name}] STT ready")

    def _start(self):
        """Start listening."""
        if self._transcriber:
            self._transcriber.start()
            log(f"[{self.name}] Started listening")

    def _stop(self):
        """Stop listening."""
        if self._transcriber:
            self._transcriber.stop()
            log(f"[{self.name}] Stopped listening")

    def _configure(self, options: dict):
        """Handle runtime configuration."""
        if "mute" in options:
            self._set_mute(options["mute"])

    def _cleanup(self):
        """Release resources."""
        if self._transcriber:
            self._transcriber.stop()

    def _set_mute(self, muted: bool):
        """Mute/unmute the microphone."""
        self._muted = muted
        if self._transcriber:
            if muted:
                self._transcriber.mute()
            else:
                self._transcriber.unmute()
        log(f"[{self.name}] {'Muted' if muted else 'Unmuted'}")

    def _on_transcription(self, result):
        """Handle transcription result from STT."""
        text = result.text.strip()
        if not text:
            return

        self.emit_signal(
            content=text,
            priority=PRIORITY_VOICE,
            duration_ms=result.duration_ms,
            language=result.language,
            confidence=result.confidence,
        )

    def _on_interrupt(self, text: str):
        """Handle interrupt detection (user said trigger word while speaking)."""
        self.emit_signal(
            content=text,
            priority=PRIORITY_INTERRUPT,
            is_interrupt=True,
        )
