"""
Screen Sense - Screen capture perception for Kira.

Captures screenshots and analyzes them using VLM to understand
what the user is working on. Great for engineering pairing.

This sense demonstrates how to create a new perception module
that uses the same VLM infrastructure as vision but with a
different input source.
"""

import sys
import os
import time
import threading
import hashlib
from typing import Optional
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from base import BaseSense
from protocol import PRIORITY_SCREEN, log


class ScreenSense(BaseSense):
    """
    Screen capture perception using VLM.

    Configuration options:
        hz: Capture frequency (default: 0.5 - every 2 seconds)
        monitor: Monitor index to capture (default: 0 - primary)
        change_threshold: How different screen must be to trigger analysis (0-1)
    """

    name = "screen"
    default_priority = PRIORITY_SCREEN

    def __init__(self):
        super().__init__()
        self._thread: Optional[threading.Thread] = None
        self._vlm = None
        self._last_hash: Optional[str] = None

        self._config = {
            "hz": 0.5,  # Every 2 seconds
            "monitor": 0,  # Primary monitor
            "change_threshold": 0.1,  # 10% pixel change to trigger
        }

    def _initialize(self):
        """Load VLM model for screen analysis."""
        log(f"[{self.name}] Loading VLM for screen analysis...")

        # Reuse the same VLM as vision sense
        from vision.vlm.moondream import FastVLM

        self._vlm = FastVLM()

        log(f"[{self.name}] VLM ready")

    def _start(self):
        """Start screen capture loop."""
        self._thread = threading.Thread(target=self._capture_loop, daemon=True)
        self._thread.start()
        log(f"[{self.name}] Started at {self._config['hz']}Hz")

    def _stop(self):
        """Stop capture loop."""
        self.running = False
        if self._thread:
            self._thread.join(timeout=2.0)
        log(f"[{self.name}] Stopped")

    def _capture_loop(self):
        """Main capture and analysis loop."""
        interval = 1.0 / self._config["hz"]

        while self.running:
            loop_start = time.time()

            try:
                screenshot = self._capture_screen()
                if screenshot is None:
                    time.sleep(0.5)
                    continue

                # Check if screen changed significantly
                if not self._screen_changed(screenshot):
                    elapsed = time.time() - loop_start
                    sleep_time = max(0, interval - elapsed)
                    time.sleep(sleep_time)
                    continue

                # Analyze the screen
                result = self._analyze(screenshot)
                if result:
                    self._emit_observation(result)

            except Exception as e:
                log(f"[{self.name}] Error: {e}")

            elapsed = time.time() - loop_start
            sleep_time = max(0, interval - elapsed)
            time.sleep(sleep_time)

    def _capture_screen(self) -> Optional[np.ndarray]:
        """Capture screenshot. Returns RGB numpy array."""
        try:
            # Use mss for cross-platform screen capture
            import mss

            with mss.mss() as sct:
                monitors = sct.monitors
                if self._config["monitor"] >= len(monitors):
                    monitor = monitors[1]  # Primary monitor (0 is "all")
                else:
                    monitor = monitors[self._config["monitor"] + 1]

                screenshot = sct.grab(monitor)

                # Convert to numpy RGB
                img = np.array(screenshot)
                # mss returns BGRA, convert to RGB
                rgb = img[:, :, :3][:, :, ::-1]
                return rgb

        except ImportError:
            log(f"[{self.name}] mss not installed. Run: pip install mss")
            return None
        except Exception as e:
            log(f"[{self.name}] Screenshot failed: {e}")
            return None

    def _screen_changed(self, screenshot: np.ndarray) -> bool:
        """Check if screen changed significantly from last capture."""
        # Simple hash-based change detection
        # Downsample heavily for fast comparison
        small = screenshot[::20, ::20, :]
        current_hash = hashlib.md5(small.tobytes()).hexdigest()

        if self._last_hash is None:
            self._last_hash = current_hash
            return True

        changed = current_hash != self._last_hash
        self._last_hash = current_hash
        return changed

    def _analyze(self, screenshot: np.ndarray) -> Optional[dict]:
        """Analyze screenshot with VLM."""
        if self._vlm is None:
            return None

        # Use full analysis for screen (we want detailed descriptions)
        result = self._vlm.analyze(screenshot, include_activity=True)

        if result is None:
            return None

        return {"description": result.summary, "inference_ms": result.inference_ms}

    def _emit_observation(self, result: dict):
        """Convert analysis result to signal."""
        description = result.get("description", "")
        inference_ms = result.get("inference_ms", 0)

        self.emit_signal(
            content=f"[Screen] {description}",
            description=description,
            inference_ms=inference_ms,
        )
