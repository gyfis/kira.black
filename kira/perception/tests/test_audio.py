"""Tests for audio processing modules (STT, VAD, echo cancellation)."""

import pytest
import numpy as np
from unittest.mock import Mock, patch, MagicMock
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))


class TestSileroVAD:
    """Test VAD functionality."""

    def test_vad_initializes_with_defaults(self):
        """VAD should initialize with sensible defaults."""
        from audio.vad import SileroVAD, SAMPLE_RATE

        vad = SileroVAD()

        assert vad.threshold == 0.5
        assert vad.min_speech_samples == int(SAMPLE_RATE * 250 / 1000)
        assert vad.min_silence_samples == int(SAMPLE_RATE * 300 / 1000)

    def test_vad_reset_clears_state(self):
        """Reset should clear all buffered audio and state."""
        from audio.vad import SileroVAD

        vad = SileroVAD()
        vad._speech_buffer = [np.zeros(512)]
        vad._speech_samples = 1000
        vad._silence_samples = 500
        vad._in_speech = True

        vad.reset()

        assert vad._speech_buffer == []
        assert vad._speech_samples == 0
        assert vad._silence_samples == 0
        assert not vad._in_speech

    def test_vad_callback_on_speech_segment(self):
        """VAD should call callback when speech segment is complete."""
        from audio.vad import SileroVAD, SpeechSegment

        callback = Mock()
        vad = SileroVAD(on_speech_segment=callback)

        # Simulate speech followed by silence
        vad._speech_buffer = [np.zeros(512) for _ in range(20)]
        vad._speech_samples = 10240  # More than min_speech_samples
        vad._in_speech = True
        vad._speech_start_time = 1.0

        vad._emit_segment()

        callback.assert_called_once()
        segment = callback.call_args[0][0]
        assert isinstance(segment, SpeechSegment)


class TestFastWhisperTranscriber:
    """Test FastWhisperTranscriber mute/unmute functionality."""

    @patch('audio.fast_whisper_service.get_model')
    def test_transcriber_initializes(self, mock_get_model):
        """Transcriber should initialize without starting."""
        from audio.fast_whisper_service import FastWhisperTranscriber

        transcriber = FastWhisperTranscriber(model_size="tiny")

        assert not transcriber._running
        assert not transcriber._muted

    @patch('audio.fast_whisper_service.get_model')
    def test_mute_sets_flag_and_resets_vad(self, mock_get_model):
        """Mute should set flag and reset VAD buffer."""
        from audio.fast_whisper_service import FastWhisperTranscriber

        transcriber = FastWhisperTranscriber()
        transcriber.vad._speech_buffer = [np.zeros(512)]
        transcriber.vad._in_speech = True

        transcriber.mute()

        assert transcriber._muted
        assert transcriber.vad._speech_buffer == []
        assert not transcriber.vad._in_speech

    @patch('audio.fast_whisper_service.get_model')
    def test_unmute_clears_flag_and_resets_vad(self, mock_get_model):
        """Unmute should clear flag and reset VAD buffer."""
        from audio.fast_whisper_service import FastWhisperTranscriber

        transcriber = FastWhisperTranscriber()
        transcriber._muted = True
        transcriber.vad._speech_buffer = [np.zeros(512)]

        transcriber.unmute()

        assert not transcriber._muted
        assert transcriber.vad._speech_buffer == []

    @patch('audio.fast_whisper_service.get_model')
    def test_muted_transcriber_skips_regular_transcription(self, mock_get_model):
        """When muted, regular transcription callback should not fire."""
        from audio.fast_whisper_service import FastWhisperTranscriber
        from audio.vad import SpeechSegment

        transcription_callback = Mock()
        mock_model = Mock()
        mock_model.transcribe.return_value = (
            [Mock(text="Hello world")],
            Mock(language="en")
        )
        mock_get_model.return_value = mock_model

        transcriber = FastWhisperTranscriber(on_transcription=transcription_callback)
        transcriber._muted = True

        segment = SpeechSegment(
            audio=np.zeros(16000, dtype=np.float32),
            start_time=1.0,
            end_time=2.0,
            duration_ms=1000
        )
        transcriber._handle_speech(segment)

        transcription_callback.assert_not_called()

    @patch('audio.fast_whisper_service.get_model')
    def test_muted_transcriber_still_detects_interrupts(self, mock_get_model):
        """When muted, interrupt keywords should still trigger callback."""
        from audio.fast_whisper_service import FastWhisperTranscriber
        from audio.vad import SpeechSegment

        interrupt_callback = Mock()
        mock_model = Mock()
        mock_model.transcribe.return_value = (
            [Mock(text="Kira stop")],
            Mock(language="en")
        )
        mock_get_model.return_value = mock_model

        transcriber = FastWhisperTranscriber(on_interrupt=interrupt_callback)
        transcriber._muted = True

        segment = SpeechSegment(
            audio=np.zeros(16000, dtype=np.float32),
            start_time=1.0,
            end_time=2.0,
            duration_ms=1000
        )
        transcriber._handle_speech(segment)

        interrupt_callback.assert_called_once_with("Kira stop")

    @patch('audio.fast_whisper_service.get_model')
    def test_interrupt_keywords_detection(self, mock_get_model):
        """Test interrupt keyword detection."""
        from audio.fast_whisper_service import FastWhisperTranscriber

        transcriber = FastWhisperTranscriber()

        assert transcriber._is_interrupt("Kira, what's up?")
        assert transcriber._is_interrupt("Stop talking")
        assert transcriber._is_interrupt("Wait a second")
        assert transcriber._is_interrupt("QUIET please")
        assert not transcriber._is_interrupt("Hello there")
        assert not transcriber._is_interrupt("How are you?")


class TestEchoCancellationManager:
    """Test EchoCancellationManager."""

    def test_manager_initializes_in_listening_state(self):
        """Manager should start in LISTENING state."""
        from audio.echo_cancellation import EchoCancellationManager, AudioState

        manager = EchoCancellationManager()

        assert manager.state == AudioState.LISTENING
        assert manager.is_mic_active

    def test_start_speaking_changes_state(self):
        """start_speaking should change state to SPEAKING."""
        from audio.echo_cancellation import EchoCancellationManager, AudioState

        manager = EchoCancellationManager()

        manager.start_speaking()

        assert manager.state == AudioState.SPEAKING
        assert not manager.is_mic_active

    def test_stop_speaking_returns_to_listening(self):
        """stop_speaking should return to LISTENING state."""
        from audio.echo_cancellation import EchoCancellationManager, AudioState

        manager = EchoCancellationManager()
        manager.start_speaking()

        manager.stop_speaking()

        assert manager.state == AudioState.LISTENING
        assert manager.is_mic_active

    def test_state_change_callback_fires(self):
        """State change callback should be called on transitions."""
        from audio.echo_cancellation import EchoCancellationManager, AudioState

        callback = Mock()
        manager = EchoCancellationManager(on_state_change=callback)

        manager.start_speaking()

        callback.assert_called_with(AudioState.SPEAKING)

    def test_double_start_speaking_is_idempotent(self):
        """Calling start_speaking twice should not cause issues."""
        from audio.echo_cancellation import EchoCancellationManager, AudioState

        callback = Mock()
        manager = EchoCancellationManager(on_state_change=callback)

        manager.start_speaking()
        manager.start_speaking()

        # Should only be called once
        assert callback.call_count == 1


class TestSimpleEchoCancellation:
    """Test SimpleEchoCancellation."""

    def test_simple_echo_starts_unmuted(self):
        """SimpleEchoCancellation should start unmuted."""
        from audio.echo_cancellation import SimpleEchoCancellation

        echo = SimpleEchoCancellation()

        assert not echo.is_muted

    def test_simple_echo_mute_unmute(self):
        """Mute and unmute should toggle state."""
        from audio.echo_cancellation import SimpleEchoCancellation

        echo = SimpleEchoCancellation()

        echo.mute()
        assert echo.is_muted

        echo.unmute()
        assert not echo.is_muted
