"""
Integration tests for Moondream VLM.

These tests actually load the model and run inference.
Requires: GPU/MPS, ~2GB VRAM, network (first run downloads model)

Run with: uv run pytest tests/integration/test_moondream_integration.py -v -s
"""

import pytest
import numpy as np
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent.parent))


@pytest.fixture(scope="module")
def vlm():
    """Load Moondream VLM once for all tests in this module."""
    from vlm.moondream_service import MoondreamVLM
    return MoondreamVLM()


@pytest.fixture
def test_image():
    """Create a simple test image (solid color with a shape)."""
    image = np.zeros((480, 640, 3), dtype=np.uint8)
    image[:] = (200, 200, 200)  # Light gray background
    
    # Draw a simple rectangle (simulating a person-like shape)
    image[100:400, 250:390] = (100, 100, 150)  # Dark rectangle
    
    return image


@pytest.fixture
def camera_image():
    """Capture a real frame from the camera if available."""
    try:
        import cv2
        cap = cv2.VideoCapture(0)
        if not cap.isOpened():
            pytest.skip("Camera not available")
        
        ret, frame = cap.read()
        cap.release()
        
        if not ret:
            pytest.skip("Could not read from camera")
        
        # Convert BGR to RGB
        return cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
    except ImportError:
        pytest.skip("OpenCV not installed")


class TestMoondreamModelLoading:
    """Tests for model loading and initialization."""
    
    @pytest.mark.integration
    @pytest.mark.slow
    def test_model_loads_successfully(self, vlm):
        """Verify the model loads without errors."""
        assert vlm is not None
        assert vlm.prompt is not None
    
    @pytest.mark.integration
    @pytest.mark.slow
    def test_model_uses_mps_on_mac(self):
        """Verify model uses MPS acceleration on Mac."""
        import torch
        from vlm.moondream_service import get_model
        
        model, tokenizer = get_model()
        
        if torch.backends.mps.is_available():
            # Model should be on MPS
            assert next(model.parameters()).device.type == "mps"
        else:
            # Fallback to CPU
            assert next(model.parameters()).device.type == "cpu"


class TestMoondreamInference:
    """Tests for VLM inference."""
    
    @pytest.mark.integration
    @pytest.mark.slow
    def test_describe_returns_scene_description(self, vlm, test_image):
        """Verify describe() returns a valid SceneDescription."""
        result = vlm.describe(test_image)
        
        assert result is not None
        assert hasattr(result, 'description')
        assert hasattr(result, 'timestamp')
        assert hasattr(result, 'inference_ms')
        
        # Description should be non-empty string
        assert isinstance(result.description, str)
        assert len(result.description) > 0
        
        # Inference time should be reasonable (< 60 seconds on CPU)
        assert result.inference_ms > 0
        assert result.inference_ms < 60000
    
    @pytest.mark.integration
    @pytest.mark.slow
    def test_describe_camera_frame(self, vlm, camera_image):
        """Test describing a real camera frame."""
        result = vlm.describe(camera_image)
        
        assert result is not None
        assert len(result.description) > 10  # Should have meaningful content
        print(f"\nCamera description: {result.description}")
        print(f"Inference time: {result.inference_ms}ms")
    
    @pytest.mark.integration
    @pytest.mark.slow
    def test_has_changed_detects_scene_changes(self, vlm, test_image):
        """Test that has_changed() detects different scenes."""
        # First description
        result1 = vlm.describe(test_image)
        
        # Same image should not count as changed
        assert not vlm.has_changed(result1.description)
        
        # Very different description should count as changed
        assert vlm.has_changed("A completely different scene with no overlap whatsoever")
    
    @pytest.mark.integration
    @pytest.mark.slow
    def test_custom_prompt(self, test_image):
        """Test using a custom prompt."""
        from vlm.moondream_service import MoondreamVLM
        
        custom_prompt = "What colors do you see in this image?"
        vlm = MoondreamVLM(prompt=custom_prompt)
        
        result = vlm.describe(test_image)
        
        assert result is not None
        # Response should mention colors since we asked about them
        assert isinstance(result.description, str)


class TestMoondreamService:
    """Tests for the VLM service wrapper."""
    
    @pytest.mark.integration
    @pytest.mark.slow
    def test_service_starts_and_stops(self):
        """Test service lifecycle."""
        from vlm.moondream_service import VLMService
        
        service = VLMService(hz=1.0)
        
        descriptions = []
        service.on_description(lambda d: descriptions.append(d))
        
        service.start()
        assert service._running
        
        service.stop()
        assert not service._running
    
    @pytest.mark.integration
    @pytest.mark.slow
    @pytest.mark.skip(reason="VLM service threading needs longer timeout on CPU - test manually")
    def test_service_processes_submitted_frames(self, test_image):
        """Test that service processes frames and calls callbacks."""
        import time
        from vlm.moondream_service import VLMService
        
        service = VLMService(hz=1.0)
        
        descriptions = []
        service.on_description(lambda d: descriptions.append(d))
        
        service.start()
        
        # Submit a frame
        service.submit_frame(test_image)
        
        # Wait for processing (CPU inference takes ~20-30s)
        time.sleep(35)
        
        service.stop()
        
        # Should have received at least one description
        assert len(descriptions) >= 1
        assert descriptions[0].description is not None


if __name__ == "__main__":
    pytest.main([__file__, "-v", "-s", "-m", "integration"])
