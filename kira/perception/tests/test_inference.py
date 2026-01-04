"""Tests for the perception inference module."""

import pytest
import numpy as np
from unittest.mock import Mock, patch


def test_detection_dataclass():
    """Test Detection dataclass creation."""
    from perception.inference import Detection
    
    det = Detection(
        class_id=0,
        class_name='person',
        bbox=[0.1, 0.2, 0.3, 0.4],
        confidence=0.95
    )
    
    assert det.class_id == 0
    assert det.class_name == 'person'
    assert len(det.bbox) == 4
    assert det.confidence == 0.95


def test_inference_result_dataclass():
    """Test InferenceResult dataclass."""
    from perception.inference import InferenceResult, Detection
    
    result = InferenceResult(
        detections=[
            Detection(0, 'person', [0.1, 0.2, 0.3, 0.4], 0.9)
        ],
        poses=[],
        inference_latency_ms=25.0
    )
    
    assert len(result.detections) == 1
    assert result.inference_latency_ms == 25.0


def test_pose_keypoints():
    """Test POSE_KEYPOINTS constant."""
    from perception.inference import POSE_KEYPOINTS
    
    assert 'nose' in POSE_KEYPOINTS
    assert 'left_shoulder' in POSE_KEYPOINTS
    assert 'right_ankle' in POSE_KEYPOINTS
    assert len(POSE_KEYPOINTS) == 17


class TestPerceptionModels:
    """Test PerceptionModels class."""
    
    def test_init_without_load(self):
        """Models should not load on init."""
        from perception.inference import PerceptionModels
        from perception.config import ModelConfig
        
        models = PerceptionModels(ModelConfig())
        
        assert models.detector is None
        assert models.pose_model is None
        assert not models._loaded
    
    @patch('ultralytics.YOLO')
    def test_load_models(self, mock_yolo):
        """Test model loading."""
        from perception.inference import PerceptionModels
        from perception.config import ModelConfig
        
        models = PerceptionModels(ModelConfig(
            object_detection=True,
            pose_estimation=True
        ))
        
        models.load()
        
        assert mock_yolo.call_count == 2
        assert models._loaded
    
    @patch('ultralytics.YOLO')
    def test_process_returns_result(self, mock_yolo):
        """Test process method returns InferenceResult."""
        from perception.inference import PerceptionModels, InferenceResult
        from perception.config import ModelConfig
        
        mock_detector = Mock()
        mock_detector.return_value = [Mock(boxes=[], names={})]
        mock_yolo.return_value = mock_detector
        
        models = PerceptionModels(ModelConfig(
            object_detection=True,
            pose_estimation=False
        ))
        
        image = np.zeros((720, 1280, 3), dtype=np.uint8)
        result = models.process(image)
        
        assert isinstance(result, InferenceResult)
        assert result.inference_latency_ms >= 0


class TestConfig:
    """Test configuration classes."""
    
    def test_camera_config_defaults(self):
        """Test CameraConfig defaults."""
        from perception.config import CameraConfig
        
        config = CameraConfig()
        
        assert config.device_id == 0
        assert config.width == 1280
        assert config.height == 720
        assert config.fps == 30
    
    def test_perception_config_from_env(self):
        """Test PerceptionConfig.from_env."""
        from perception.config import PerceptionConfig
        import os
        
        os.environ['KIRA_SOCKET_PATH'] = '/tmp/test.sock'
        
        config = PerceptionConfig.from_env()
        
        assert config.socket_path == '/tmp/test.sock'
        
        del os.environ['KIRA_SOCKET_PATH']
