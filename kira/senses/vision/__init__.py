"""
Vision Sense for Kira.

Perceives through the camera using a Vision-Language Model (VLM).
Default implementation uses Moondream2 for emotion and activity detection.
"""

from .sense import VisionSense

__all__ = ["VisionSense"]
