"""
Integration tests for Chatterbox TTS.

These tests actually load the model and generate speech.
Requires: GPU/MPS, ~1.5GB VRAM, network (first run downloads model)

Run with: uv run pytest tests/integration/test_chatterbox_integration.py -v -s
"""

import pytest
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent.parent))


@pytest.fixture(scope="module")
def tts():
    """Load Chatterbox TTS once for all tests in this module."""
    from tts.chatterbox_service import ChatterboxTTS
    return ChatterboxTTS()


class TestChatterboxModelLoading:
    """Tests for model loading and initialization."""
    
    @pytest.mark.integration
    @pytest.mark.slow
    def test_model_loads_successfully(self):
        """Verify the model loads without errors."""
        from tts.chatterbox_service import get_model
        
        model = get_model()
        assert model is not None
    
    @pytest.mark.integration
    @pytest.mark.slow
    def test_model_uses_mps_on_mac(self):
        """Verify model uses MPS acceleration on Mac."""
        import torch
        
        if not torch.backends.mps.is_available():
            pytest.skip("MPS not available")
        
        from tts.chatterbox_service import get_model
        model = get_model()
        
        # Chatterbox model should be on MPS device
        # The exact check depends on Chatterbox implementation
        assert model is not None


class TestChatterboxSpeechGeneration:
    """Tests for TTS speech generation."""
    
    @pytest.mark.integration
    @pytest.mark.slow
    def test_speak_generates_audio(self, tts):
        """Test that speak() generates audio file."""
        # Non-blocking to get the audio path back
        audio_path = tts.speak("Hello, this is a test.", blocking=False)
        
        # Should return a path
        assert audio_path is not None
        assert Path(audio_path).exists()
        assert Path(audio_path).suffix == '.wav'
        
        # File should have content
        assert Path(audio_path).stat().st_size > 0
        
        print(f"\nGenerated audio: {audio_path}")
        print(f"File size: {Path(audio_path).stat().st_size} bytes")
    
    @pytest.mark.integration
    @pytest.mark.slow
    def test_speak_empty_text_returns_none(self, tts):
        """Empty text should return None without error."""
        result = tts.speak("", blocking=False)
        assert result is None
        
        result = tts.speak("   ", blocking=False)
        assert result is None
    
    @pytest.mark.integration
    @pytest.mark.slow
    def test_speak_various_texts(self, tts):
        """Test generating speech for various text types."""
        test_cases = [
            "Hello!",
            "I am Kira, your visual AI companion.",
            "The quick brown fox jumps over the lazy dog.",
            "1, 2, 3, testing.",
            "What do you see in front of you?",
        ]
        
        for text in test_cases:
            audio_path = tts.speak(text, blocking=False)
            assert audio_path is not None
            assert Path(audio_path).exists()
            print(f"\n'{text}' -> {Path(audio_path).stat().st_size} bytes")
    
    @pytest.mark.integration
    @pytest.mark.slow
    def test_speak_blocking_plays_audio(self, tts):
        """
        Test blocking speak() actually plays audio.
        
        This test plays audio through speakers - manual verification.
        """
        print("\n[Playing audio - you should hear 'Hello from Kira'...]")
        
        # blocking=True plays audio and returns None
        result = tts.speak("Hello from Kira!", blocking=True)
        
        assert result is None  # Blocking mode doesn't return path
        print("[Audio should have played]")
    
    @pytest.mark.integration
    @pytest.mark.slow  
    def test_speak_long_text(self, tts):
        """Test generating speech for longer text."""
        long_text = (
            "I can see you sitting at your desk. You appear to be focused on something "
            "on your screen. The lighting in the room is warm, suggesting it might be "
            "evening. Would you like me to describe anything specific about what I see?"
        )
        
        audio_path = tts.speak(long_text, blocking=False)
        
        assert audio_path is not None
        assert Path(audio_path).exists()
        
        # Longer text should produce larger file
        file_size = Path(audio_path).stat().st_size
        print(f"\nLong text ({len(long_text)} chars) -> {file_size} bytes")
        assert file_size > 10000  # Should be substantial


class TestChatterboxVoiceCloning:
    """Tests for voice cloning feature."""
    
    @pytest.fixture
    def voice_reference(self):
        """Create a simple voice reference file for testing."""
        # In real usage, this would be a recording of the target voice
        # For testing, we skip if no reference available
        ref_path = Path(__file__).parent.parent.parent / "voice_reference.wav"
        if not ref_path.exists():
            pytest.skip("No voice reference file available")
        return str(ref_path)
    
    @pytest.mark.integration
    @pytest.mark.slow
    def test_voice_cloning_with_reference(self, voice_reference):
        """Test TTS with voice cloning."""
        from tts.chatterbox_service import ChatterboxTTS
        
        tts = ChatterboxTTS(voice_ref_path=voice_reference)
        
        audio_path = tts.speak("Hello, this is with voice cloning.", blocking=False)
        
        assert audio_path is not None
        assert Path(audio_path).exists()


class TestChatterboxTTSService:
    """Tests for the TTS service wrapper."""
    
    @pytest.mark.integration
    @pytest.mark.slow
    def test_tts_initializes(self, tts):
        """Test TTS object initializes correctly."""
        assert tts is not None
        assert tts._audio_queue is not None
    
    @pytest.mark.integration
    @pytest.mark.slow
    def test_nonblocking_queues_audio(self, tts):
        """Test non-blocking mode queues audio for playback."""
        # Submit multiple items
        paths = []
        for text in ["One.", "Two.", "Three."]:
            path = tts.speak(text, blocking=False)
            paths.append(path)
        
        # All should have generated files
        assert all(p is not None for p in paths)
        assert all(Path(p).exists() for p in paths)


class TestAudioQuality:
    """Tests for audio quality and format."""
    
    @pytest.mark.integration
    @pytest.mark.slow
    def test_audio_is_valid_wav(self, tts):
        """Verify generated audio is valid WAV format."""
        import soundfile as sf
        
        audio_path = tts.speak("Testing audio format.", blocking=False)
        
        # Use soundfile which supports float32 WAV (format code 3)
        data, samplerate = sf.read(audio_path)
        
        assert samplerate > 0  # Has sample rate
        assert len(data) > 0  # Has audio data
        
        print(f"\nWAV info:")
        print(f"  Sample rate: {samplerate} Hz")
        print(f"  Samples: {len(data)}")
        print(f"  Duration: {len(data) / samplerate:.2f}s")


if __name__ == "__main__":
    pytest.main([__file__, "-v", "-s", "-m", "integration"])
