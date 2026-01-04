"""
Screen Sense for Kira.

Perceives what's on screen through periodic screenshots and VLM analysis.
Useful for engineering pairing, helping with code, or seeing what you're working on.
"""

from .sense import ScreenSense

__all__ = ["ScreenSense"]
