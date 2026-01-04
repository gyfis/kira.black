"""
Vision Sense entry point.

Run with: python -m senses.vision
"""

import sys
import os

# Ensure senses package is in path
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from vision.sense import VisionSense

if __name__ == "__main__":
    sense = VisionSense()
    sense.run()
