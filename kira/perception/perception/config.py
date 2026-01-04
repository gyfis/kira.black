"""Configuration for perception service."""

from dataclasses import dataclass, field
from typing import Optional
import os


@dataclass
class CameraConfig:
    device_id: int = 0
    width: int = 1280
    height: int = 720
    fps: int = 30


@dataclass
class ModelConfig:
    object_detection: bool = True
    pose_estimation: bool = True
    detection_model: str = "yolov8n.pt"
    pose_model: str = "yolov8n-pose.pt"
    confidence_threshold: float = 0.5


@dataclass
class PerceptionConfig:
    socket_path: str = "/tmp/kira.sock"
    camera: CameraConfig = field(default_factory=CameraConfig)
    models: ModelConfig = field(default_factory=ModelConfig)
    
    @classmethod
    def from_env(cls) -> "PerceptionConfig":
        """Load configuration from environment variables."""
        return cls(
            socket_path=os.getenv("KIRA_SOCKET_PATH", "/tmp/kira.sock"),
            camera=CameraConfig(
                device_id=int(os.getenv("KIRA_CAMERA_DEVICE", "0")),
                width=int(os.getenv("KIRA_CAMERA_WIDTH", "1280")),
                height=int(os.getenv("KIRA_CAMERA_HEIGHT", "720")),
                fps=int(os.getenv("KIRA_CAMERA_FPS", "30")),
            ),
            models=ModelConfig(
                object_detection=os.getenv("KIRA_MODEL_DETECTION", "true").lower() == "true",
                pose_estimation=os.getenv("KIRA_MODEL_POSE", "true").lower() == "true",
                confidence_threshold=float(os.getenv("KIRA_CONFIDENCE_THRESHOLD", "0.5")),
            ),
        )
