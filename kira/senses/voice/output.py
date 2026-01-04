"""
Voice Output - Speech output for Kira.

Uses Text-to-Speech (TTS) to speak responses to the user.
"""

import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from base import BaseOutput
from protocol import log


class VoiceOutput(BaseOutput):
    """
    Speech output using TTS.

    Configuration options:
        voice_path: Path to Piper voice model
    """

    name = "voice"

    def __init__(self):
        super().__init__()
        self._tts = None
        self._config = {
            "voice_path": None,  # Uses default
        }

    def _initialize(self):
        """Load TTS model."""
        log(f"[{self.name}] Loading TTS model...")
        from tts.piper import PiperTTS

        self._tts = PiperTTS(voice_path=self._config.get("voice_path"))
        log(f"[{self.name}] TTS ready")

    def _output(self, content: str, **options):
        """Speak the content."""
        if self._tts:
            blocking = options.get("blocking", True)
            self._tts.speak(content, blocking=blocking)

    def _interrupt(self):
        """Stop current speech."""
        if self._tts:
            self._tts.interrupt()

    def _cleanup(self):
        """Release resources."""
        if self._tts:
            self._tts.interrupt()
