"""Camera capture module for webcam video acquisition."""

import cv2
import numpy as np
import time
from dataclasses import dataclass
from typing import Optional

from .config import CameraConfig


@dataclass
class CapturedFrame:
    """A single captured frame with metadata."""
    frame_id: int
    timestamp_ms: int
    image: np.ndarray
    capture_latency_ms: float
    width: int
    height: int


class CameraCapture:
    """Manages camera capture with proper buffering and timing."""
    
    def __init__(self, config: Optional[CameraConfig] = None):
        self.config = config or CameraConfig()
        self.cap: Optional[cv2.VideoCapture] = None
        self.frame_id = 0
        self.start_time: Optional[float] = None
        self._is_open = False
    
    def open(self) -> bool:
        """Open the camera device."""
        self.cap = cv2.VideoCapture(self.config.device_id)
        
        if not self.cap.isOpened():
            return False
        
        # Configure camera settings
        self.cap.set(cv2.CAP_PROP_FRAME_WIDTH, self.config.width)
        self.cap.set(cv2.CAP_PROP_FRAME_HEIGHT, self.config.height)
        self.cap.set(cv2.CAP_PROP_FPS, self.config.fps)
        
        # Reduce buffer size for lower latency
        self.cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)
        
        self.start_time = time.time()
        self._is_open = True
        
        # Read actual settings (may differ from requested)
        actual_width = int(self.cap.get(cv2.CAP_PROP_FRAME_WIDTH))
        actual_height = int(self.cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
        actual_fps = self.cap.get(cv2.CAP_PROP_FPS)
        
        print(f"Camera opened: {actual_width}x{actual_height} @ {actual_fps:.1f} FPS")
        
        return True
    
    def read(self) -> Optional[CapturedFrame]:
        """Read a single frame from the camera."""
        if not self._is_open or self.cap is None:
            return None
        
        t0 = time.perf_counter()
        ret, frame = self.cap.read()
        capture_latency_ms = (time.perf_counter() - t0) * 1000
        
        if not ret or frame is None:
            return None
        
        self.frame_id += 1
        timestamp_ms = int((time.time() - self.start_time) * 1000)
        
        return CapturedFrame(
            frame_id=self.frame_id,
            timestamp_ms=timestamp_ms,
            image=frame,
            capture_latency_ms=capture_latency_ms,
            width=frame.shape[1],
            height=frame.shape[0],
        )
    
    def release(self):
        """Release the camera device."""
        if self.cap is not None:
            self.cap.release()
            self._is_open = False
            self.cap = None
    
    @property
    def is_open(self) -> bool:
        return self._is_open
    
    def __enter__(self):
        self.open()
        return self
    
    def __exit__(self, exc_type, exc_val, exc_tb):
        self.release()
        return False
