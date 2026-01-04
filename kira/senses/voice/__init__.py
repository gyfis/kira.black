"""
Voice Output for Kira.

Produces speech output using Text-to-Speech (TTS).
Default implementation uses Piper for fast local TTS.
"""

from .output import VoiceOutput

__all__ = ["VoiceOutput"]
