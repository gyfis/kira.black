"""
Integration tests for Whisper STT.

These tests actually load the model and run inference.
Requires: Microphone access, ~1GB VRAM, network (first run downloads model)

Run with: uv run pytest tests/integration/test_whisper_integration.py -v -s
"""

import pytest
import numpy as np
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent.parent))


@pytest.fixture(scope="module")
def whisper_model():
    """Load Whisper model once for all tests in this module."""
    from audio.whisper_service import get_model
    return get_model(model_name="base")


@pytest.fixture
def silent_audio():
    """Generate silent audio (16kHz, 1 second)."""
    return np.zeros(16000, dtype=np.float32)


@pytest.fixture
def tone_audio():
    """Generate a simple tone (440Hz sine wave, 16kHz, 1 second)."""
    t = np.linspace(0, 1, 16000, dtype=np.float32)
    return 0.5 * np.sin(2 * np.pi * 440 * t)


@pytest.fixture
def speech_audio():
    """
    Try to capture real speech from microphone.
    Falls back to generating a test tone if mic unavailable.
    """
    try:
        import sounddevice as sd
        
        print("\n[Recording 3 seconds of audio - please speak...]")
        audio = sd.rec(int(3 * 16000), samplerate=16000, channels=1, dtype=np.float32)
        sd.wait()
        
        return audio.flatten()
    except Exception as e:
        pytest.skip(f"Could not record audio: {e}")


class TestWhisperModelLoading:
    """Tests for model loading and initialization."""
    
    @pytest.mark.integration
    @pytest.mark.slow
    def test_model_loads_successfully(self, whisper_model):
        """Verify the model loads without errors."""
        assert whisper_model is not None
    
    @pytest.mark.integration
    @pytest.mark.slow
    def test_model_has_transcribe_method(self, whisper_model):
        """Verify model has transcribe method."""
        assert hasattr(whisper_model, 'transcribe')


class TestWhisperTranscription:
    """Tests for speech transcription."""
    
    @pytest.mark.integration
    @pytest.mark.slow
    def test_transcribe_silent_audio(self, whisper_model, silent_audio):
        """Transcribing silence should return empty or minimal text."""
        result = whisper_model.transcribe(silent_audio, fp16=False)
        
        assert result is not None
        assert 'text' in result
        # Silent audio should produce empty or very short transcription
        assert len(result['text'].strip()) < 50
    
    @pytest.mark.integration
    @pytest.mark.slow
    def test_transcribe_real_speech(self, whisper_model, speech_audio):
        """Test transcribing real recorded speech."""
        result = whisper_model.transcribe(speech_audio, fp16=False)
        
        assert result is not None
        assert 'text' in result
        
        print(f"\nTranscribed: '{result['text']}'")
        print(f"Language: {result.get('language', 'unknown')}")
    
    @pytest.mark.integration
    @pytest.mark.slow
    def test_transcription_result_structure(self, whisper_model, silent_audio):
        """Verify transcription result has expected structure."""
        result = whisper_model.transcribe(silent_audio, fp16=False)
        
        assert 'text' in result
        assert 'language' in result
        assert 'segments' in result


class TestVoiceActivityDetector:
    """Tests for voice activity detection."""
    
    @pytest.mark.integration
    def test_vad_detects_silence(self, silent_audio):
        """VAD should detect silence."""
        from audio.whisper_service import VoiceActivityDetector
        
        vad = VoiceActivityDetector(threshold=0.01)
        
        # Process chunks of silent audio
        chunk_size = 8000  # 0.5 seconds
        for i in range(0, len(silent_audio), chunk_size):
            chunk = silent_audio[i:i+chunk_size]
            if len(chunk) == chunk_size:
                state = vad.process(chunk)
                assert state == 'silence'
    
    @pytest.mark.integration
    def test_vad_detects_speech(self, tone_audio):
        """VAD should detect loud audio as speech."""
        from audio.whisper_service import VoiceActivityDetector
        
        vad = VoiceActivityDetector(threshold=0.01)
        
        # Process chunks of tone audio
        chunk_size = 8000  # 0.5 seconds
        states = []
        for i in range(0, len(tone_audio), chunk_size):
            chunk = tone_audio[i:i+chunk_size]
            if len(chunk) == chunk_size:
                state = vad.process(chunk)
                states.append(state)
        
        # Should have detected speech
        assert 'speech_start' in states or 'speech' in states


class TestWhisperTranscriber:
    """Tests for the full transcriber service."""
    
    @pytest.mark.integration
    @pytest.mark.slow
    def test_transcriber_initializes(self):
        """Test transcriber can be created."""
        from audio.whisper_service import WhisperTranscriber
        
        transcriber = WhisperTranscriber(model_name="base")
        assert transcriber is not None
        assert transcriber.vad is not None
    
    @pytest.mark.integration
    @pytest.mark.slow
    def test_transcriber_starts_and_stops(self):
        """Test transcriber lifecycle."""
        from audio.whisper_service import WhisperTranscriber
        
        results = []
        transcriber = WhisperTranscriber(
            model_name="base",
            on_transcription=lambda r: results.append(r)
        )
        
        transcriber.start()
        assert transcriber._running
        
        # Let it run briefly
        time.sleep(1)
        
        transcriber.stop()
        assert not transcriber._running
    
    @pytest.mark.integration
    @pytest.mark.slow
    def test_transcriber_captures_speech(self):
        """
        Test that transcriber captures and transcribes speech.
        
        This test requires speaking into the microphone.
        """
        from audio.whisper_service import WhisperTranscriber
        
        results = []
        transcriber = WhisperTranscriber(
            model_name="base",
            on_transcription=lambda r: results.append(r)
        )
        
        print("\n[Starting transcriber - please speak for 5 seconds...]")
        
        transcriber.start()
        time.sleep(5)
        transcriber.stop()
        
        print(f"\nReceived {len(results)} transcriptions")
        for r in results:
            print(f"  - '{r.text}' (lang={r.language})")
        
        # Note: We don't assert on results since user might not speak
        # This test is primarily for manual verification


class TestTranscriptionResult:
    """Tests for TranscriptionResult dataclass."""
    
    @pytest.mark.integration
    def test_transcription_result_fields(self):
        """Test TranscriptionResult has all expected fields."""
        from audio.whisper_service import TranscriptionResult
        
        result = TranscriptionResult(
            text="Hello world",
            language="en",
            confidence=0.95,
            duration_ms=1234
        )
        
        assert result.text == "Hello world"
        assert result.language == "en"
        assert result.confidence == 0.95
        assert result.duration_ms == 1234


if __name__ == "__main__":
    pytest.main([__file__, "-v", "-s", "-m", "integration"])
