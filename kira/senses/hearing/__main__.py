"""
Hearing Sense entry point.

Run with: python -m senses.hearing
"""

import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from hearing.sense import HearingSense

if __name__ == "__main__":
    sense = HearingSense()
    sense.run()
