"""Tests for perception event emission format.

These tests ensure the Python perception service emits events in the exact
format expected by the Ruby UnifiedClient.
"""

import pytest
import json
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))


class TestPerceptionEventFormat:
    """Test PerceptionEvent dataclass and JSON serialization."""

    def test_perception_event_to_json(self):
        """Event should serialize to expected JSON format."""
        from kira_perception import PerceptionEvent

        event = PerceptionEvent(
            type='visual',
            data={'emotion': 'happy', 'description': 'Person smiling'},
            timestamp=1234567890.123
        )

        json_str = event.to_json()
        parsed = json.loads(json_str)

        assert parsed['type'] == 'visual'
        assert parsed['data']['emotion'] == 'happy'
        assert parsed['data']['description'] == 'Person smiling'
        assert parsed['timestamp'] == 1234567890.123

    def test_perception_event_auto_timestamp(self):
        """Event should auto-generate timestamp if not provided."""
        from kira_perception import PerceptionEvent
        import time

        before = time.time()
        event = PerceptionEvent(type='test', data={})
        after = time.time()

        assert before <= event.timestamp <= after


class TestKiraPerceptionEmitEvent:
    """Test KiraPerception._emit_event method."""

    def test_emit_visual_event_format(self):
        """Visual event should have correct structure."""
        from kira_perception import KiraPerception
        import json

        perception = KiraPerception(prewarm=False, enable_tts=False, enable_stt=False)

        # Capture emitted event
        perception._emit_event('visual', {
            'emotion': 'curious',
            'description': 'Person looking at screen',
            'inference_ms': 150,
            'frame_diff': 0.05,
            'is_full_analysis': False
        })

        event = perception.get_event(timeout=0.1)

        assert event is not None
        assert event.type == 'visual'
        assert event.data['emotion'] == 'curious'
        assert event.data['description'] == 'Person looking at screen'
        assert event.data['inference_ms'] == 150
        assert event.data['is_full_analysis'] == False

    def test_emit_visual_full_event_format(self):
        """Full visual analysis event should have correct structure."""
        from kira_perception import KiraPerception

        perception = KiraPerception(prewarm=False, enable_tts=False, enable_stt=False)

        perception._emit_event('visual_full', {
            'description': 'A person sitting at a desk, typing on a laptop',
            'inference_ms': 800,
            'is_full_analysis': True
        })

        event = perception.get_event(timeout=0.1)

        assert event.type == 'visual_full'
        assert 'typing on a laptop' in event.data['description']
        assert event.data['is_full_analysis'] == True

    def test_emit_voice_event_format(self):
        """Voice event should have correct structure."""
        from kira_perception import KiraPerception

        perception = KiraPerception(prewarm=False, enable_tts=False, enable_stt=False)

        perception._emit_event('voice', {
            'text': 'Hello Kira',
            'language': 'en',
            'latency_ms': 350
        })

        event = perception.get_event(timeout=0.1)

        assert event.type == 'voice'
        assert event.data['text'] == 'Hello Kira'
        assert event.data['language'] == 'en'

    def test_emit_interrupt_event_format(self):
        """Interrupt event should have correct structure."""
        from kira_perception import KiraPerception

        perception = KiraPerception(prewarm=False, enable_tts=False, enable_stt=False)

        perception._emit_event('interrupt', {'text': 'stop'})

        event = perception.get_event(timeout=0.1)

        assert event.type == 'interrupt'
        assert event.data['text'] == 'stop'

    def test_emit_ready_event_format(self):
        """Ready event should have correct structure."""
        from kira_perception import KiraPerception

        perception = KiraPerception(prewarm=False, enable_tts=False, enable_stt=False)

        perception._emit_event('ready', {
            'camera': True,
            'vlm_hz': 2.0,
            'stt': False,
            'tts': False,
            'prewarm': False
        })

        event = perception.get_event(timeout=0.1)

        assert event.type == 'ready'
        assert event.data['camera'] == True

    def test_emit_error_event_format(self):
        """Error event should have correct structure."""
        from kira_perception import KiraPerception

        perception = KiraPerception(prewarm=False, enable_tts=False, enable_stt=False)

        perception._emit_event('error', {'message': 'Camera failed'})

        event = perception.get_event(timeout=0.1)

        assert event.type == 'error'
        assert event.data['message'] == 'Camera failed'

    def test_emit_audio_state_event_format(self):
        """Audio state event should have correct structure."""
        from kira_perception import KiraPerception

        perception = KiraPerception(prewarm=False, enable_tts=False, enable_stt=False)

        perception._emit_event('audio_state', {'state': 'SPEAKING'})

        event = perception.get_event(timeout=0.1)

        assert event.type == 'audio_state'
        assert event.data['state'] == 'SPEAKING'


class TestEventJsonSerialization:
    """Test that events serialize correctly for IPC."""

    def test_event_json_round_trip(self):
        """Event should survive JSON round-trip."""
        from kira_perception import PerceptionEvent

        original = PerceptionEvent(
            type='visual',
            data={
                'emotion': 'happy',
                'description': 'Test description',
                'nested': {'key': 'value'}
            }
        )

        json_str = original.to_json()
        parsed = json.loads(json_str)

        assert parsed['type'] == original.type
        assert parsed['data'] == original.data
        assert parsed['timestamp'] == original.timestamp

    def test_event_json_handles_special_characters(self):
        """Event should handle special characters in text."""
        from kira_perception import PerceptionEvent

        event = PerceptionEvent(
            type='voice',
            data={'text': 'Hello "Kira"! How\'s it going? 日本語'}
        )

        json_str = event.to_json()
        parsed = json.loads(json_str)

        assert parsed['data']['text'] == 'Hello "Kira"! How\'s it going? 日本語'

    def test_event_json_handles_newlines(self):
        """Event should handle newlines in text."""
        from kira_perception import PerceptionEvent

        event = PerceptionEvent(
            type='visual',
            data={'description': 'Line 1\nLine 2\nLine 3'}
        )

        json_str = event.to_json()
        parsed = json.loads(json_str)

        assert parsed['data']['description'] == 'Line 1\nLine 2\nLine 3'


class TestSTTEventFormat:
    """Test that STT service emits events in correct format."""

    def test_transcription_result_fields(self):
        """TranscriptionResult should have expected fields."""
        from audio.fast_whisper_service import TranscriptionResult

        result = TranscriptionResult(
            text='Hello Kira',
            language='en',
            confidence=0.95,
            duration_ms=350
        )

        assert result.text == 'Hello Kira'
        assert result.language == 'en'
        assert result.confidence == 0.95
        assert result.duration_ms == 350


class TestVLMEventFormat:
    """Test that VLM service emits events in correct format."""

    def test_vlm_result_fields(self):
        """FastVLMResult should have expected fields."""
        from vlm.fast_vlm_service import FastVLMResult

        result = FastVLMResult(
            emotion='happy',
            activity='typing',
            summary='Person smiling at screen',
            inference_ms=150
        )

        assert result.emotion == 'happy'
        assert result.activity == 'typing'
        assert result.summary == 'Person smiling at screen'
        assert result.inference_ms == 150
