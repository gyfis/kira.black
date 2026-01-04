"""ML inference module for object detection and pose estimation."""

import numpy as np
from dataclasses import dataclass, field
from typing import List, Dict, Optional, Any
import time

from .config import ModelConfig


@dataclass
class Detection:
    """A single object detection result."""
    class_id: int
    class_name: str
    bbox: List[float]  # [x1, y1, x2, y2] normalized 0-1
    confidence: float


@dataclass
class PoseKeypoint:
    """A single pose keypoint."""
    name: str
    x: float  # normalized 0-1
    y: float  # normalized 0-1
    confidence: float


@dataclass
class PoseEstimate:
    """Pose estimation result for a detected person."""
    detection_idx: int
    keypoints: Dict[str, List[float]]  # {name: [x, y, confidence]}
    

@dataclass
class InferenceResult:
    """Complete inference result for a frame."""
    detections: List[Detection] = field(default_factory=list)
    poses: List[PoseEstimate] = field(default_factory=list)
    inference_latency_ms: float = 0.0


# COCO pose keypoint names
POSE_KEYPOINTS = [
    "nose", "left_eye", "right_eye", "left_ear", "right_ear",
    "left_shoulder", "right_shoulder", "left_elbow", "right_elbow",
    "left_wrist", "right_wrist", "left_hip", "right_hip",
    "left_knee", "right_knee", "left_ankle", "right_ankle"
]


class PerceptionModels:
    """Manages ML models for perception inference."""
    
    def __init__(self, config: Optional[ModelConfig] = None):
        self.config = config or ModelConfig()
        self.detector = None
        self.pose_model = None
        self._loaded = False
    
    def load(self):
        """Load ML models (lazy loading for faster startup)."""
        if self._loaded:
            return
        
        from ultralytics import YOLO
        
        print("Loading perception models...")
        t0 = time.time()
        
        if self.config.object_detection:
            print(f"  Loading detection model: {self.config.detection_model}")
            self.detector = YOLO(self.config.detection_model)
        
        if self.config.pose_estimation:
            print(f"  Loading pose model: {self.config.pose_model}")
            self.pose_model = YOLO(self.config.pose_model)
        
        self._loaded = True
        print(f"Models loaded in {time.time() - t0:.2f}s")
    
    def process(self, image: np.ndarray) -> InferenceResult:
        """Run inference on a single frame."""
        if not self._loaded:
            self.load()
        
        t0 = time.perf_counter()
        
        h, w = image.shape[:2]
        detections: List[Detection] = []
        poses: List[PoseEstimate] = []
        
        # Object detection
        if self.detector is not None:
            det_results = self.detector(image, verbose=False)[0]
            
            for i, box in enumerate(det_results.boxes):
                x1, y1, x2, y2 = box.xyxy[0].tolist()
                class_id = int(box.cls)
                
                detections.append(Detection(
                    class_id=class_id,
                    class_name=det_results.names[class_id],
                    bbox=[x1 / w, y1 / h, x2 / w, y2 / h],
                    confidence=float(box.conf),
                ))
        
        # Pose estimation
        if self.pose_model is not None:
            pose_results = self.pose_model(image, verbose=False)[0]
            
            if pose_results.keypoints is not None:
                keypoints_data = pose_results.keypoints.data
                
                for i, kpts in enumerate(keypoints_data):
                    keypoint_dict = {}
                    
                    for j, kpt in enumerate(kpts):
                        if j < len(POSE_KEYPOINTS):
                            x, y, conf = kpt.tolist()
                            keypoint_dict[POSE_KEYPOINTS[j]] = [
                                x / w, 
                                y / h, 
                                float(conf)
                            ]
                    
                    poses.append(PoseEstimate(
                        detection_idx=i,
                        keypoints=keypoint_dict,
                    ))
        
        inference_latency_ms = (time.perf_counter() - t0) * 1000
        
        return InferenceResult(
            detections=detections,
            poses=poses,
            inference_latency_ms=inference_latency_ms,
        )
    
    def to_dict(self, result: InferenceResult) -> Dict[str, Any]:
        """Convert inference result to dictionary for serialization."""
        return {
            "detections": [
                {
                    "class_id": d.class_id,
                    "class_name": d.class_name,
                    "bbox": d.bbox,
                    "confidence": d.confidence,
                }
                for d in result.detections
            ],
            "poses": [
                {
                    "detection_idx": p.detection_idx,
                    "keypoints": p.keypoints,
                }
                for p in result.poses
            ],
        }
