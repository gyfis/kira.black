"""
Screen Sense entry point.

Run with: python -m senses.screen
"""

import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from screen.sense import ScreenSense

if __name__ == "__main__":
    sense = ScreenSense()
    sense.run()
