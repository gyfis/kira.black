"""
Hearing Sense for Kira.

Perceives through the microphone using Speech-to-Text (STT).
Default implementation uses faster-whisper with Silero VAD.
"""

from .sense import HearingSense

__all__ = ["HearingSense"]
