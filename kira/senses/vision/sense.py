"""
Vision Sense - Camera-based perception for Kira.

Uses a Vision-Language Model (VLM) to understand what's happening
in front of the camera. Emits signals about user emotion and activity.
"""

import sys
import time
import threading
from typing import Optional

# Add parent to path for imports
sys.path.insert(0, str(__file__).rsplit("/", 2)[0])

from base import BaseSense
from protocol import PRIORITY_VISUAL, log


class VisionSense(BaseSense):
    """
    Camera-based perception using VLM.

    Configuration options:
        hz: Analysis frequency (default: 2.0)
        full_analysis_interval: Frames between full scene descriptions (default: 30)
        camera_index: Camera device index (default: 0)
    """

    name = "vision"
    default_priority = PRIORITY_VISUAL

    def __init__(self):
        super().__init__()
        self._thread: Optional[threading.Thread] = None
        self._camera = None
        self._vlm = None

        # Config defaults
        self._config = {
            "hz": 2.0,
            "full_analysis_interval": 30,
            "camera_index": 0,
        }

    def _initialize(self):
        """Load VLM model."""
        log(f"[{self.name}] Loading VLM model...")
        from vlm.moondream import HybridVLM

        self._vlm = HybridVLM(
            full_analysis_interval=self._config["full_analysis_interval"]
        )
        log(f"[{self.name}] VLM ready")

    def _start(self):
        """Start camera capture and analysis loop."""
        import cv2

        self._camera = cv2.VideoCapture(self._config["camera_index"])
        if not self._camera.isOpened():
            raise RuntimeError(f"Could not open camera {self._config['camera_index']}")

        self._thread = threading.Thread(target=self._perception_loop, daemon=True)
        self._thread.start()
        log(f"[{self.name}] Started at {self._config['hz']}Hz")

    def _stop(self):
        """Stop camera and analysis."""
        self.running = False
        if self._thread:
            self._thread.join(timeout=2.0)
        if self._camera:
            self._camera.release()
            self._camera = None
        log(f"[{self.name}] Stopped")

    def _configure(self, options: dict):
        """Handle runtime configuration changes."""
        if "full_analysis_interval" in options and self._vlm:
            self._vlm.full_analysis_interval = options["full_analysis_interval"]

    def _cleanup(self):
        """Release camera on shutdown."""
        if self._camera:
            self._camera.release()

    def _perception_loop(self):
        """Main perception loop - captures and analyzes frames."""
        import cv2

        interval = 1.0 / self._config["hz"]

        while self.running:
            loop_start = time.time()

            try:
                ret, frame = self._camera.read()
                if not ret:
                    log(f"[{self.name}] Failed to capture frame")
                    time.sleep(0.1)
                    continue

                # Convert BGR to RGB
                frame_rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)

                # Analyze
                result = self._vlm.analyze(frame_rgb)

                if result:
                    self._emit_observation(result)

            except Exception as e:
                log(f"[{self.name}] Error in perception loop: {e}")

            # Maintain target frequency
            elapsed = time.time() - loop_start
            sleep_time = interval - elapsed
            if sleep_time > 0:
                time.sleep(sleep_time)

    def _emit_observation(self, result: dict):
        """Convert VLM result to signal."""
        emotion = result.get("emotion", "unknown")
        activity = result.get("activity", "")
        is_full = result.get("is_full_analysis", False)
        inference_ms = result.get("inference_ms", 0)

        if is_full and activity:
            content = f"{activity} (emotion: {emotion})"
        else:
            content = f"User appears {emotion}"

        self.emit_signal(
            content=content,
            emotion=emotion,
            description=activity,
            inference_ms=inference_ms,
            is_full_analysis=is_full,
        )
