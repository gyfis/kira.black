"""
Voice Output entry point.

Run with: python -m senses.voice
"""

import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from voice.output import VoiceOutput

if __name__ == "__main__":
    output = VoiceOutput()
    output.run()
