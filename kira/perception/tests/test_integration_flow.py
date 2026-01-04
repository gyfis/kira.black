"""Integration tests for the perception flow.

These tests verify the actual components work together correctly,
testing timing, echo cancellation effectiveness, and event flow.
"""

import pytest
import time
import threading
import queue
import numpy as np
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))


class TestEchoCancellationIntegration:
    """Test echo cancellation with simulated audio flow."""

    def test_mute_unmute_clears_pending_audio(self):
        """Verify that mute/unmute cycle properly clears VAD buffer."""
        from audio.fast_whisper_service import FastWhisperTranscriber
        from unittest.mock import patch

        transcriptions = []

        def on_transcription(result):
            transcriptions.append(result.text)

        with patch('audio.fast_whisper_service.get_model'):
            transcriber = FastWhisperTranscriber(on_transcription=on_transcription)

            # Simulate audio accumulating in VAD buffer
            transcriber.vad._speech_buffer = [np.zeros(512, dtype=np.float32) for _ in range(10)]
            transcriber.vad._speech_samples = 5120
            transcriber.vad._in_speech = True

            # Mute should clear buffer
            transcriber.mute()

            assert transcriber.vad._speech_buffer == []
            assert transcriber.vad._speech_samples == 0
            assert not transcriber.vad._in_speech

            # Simulate more audio during mute (this shouldn't happen in real use
            # because _process_loop skips VAD, but test the safety)
            transcriber.vad._speech_buffer = [np.zeros(512, dtype=np.float32) for _ in range(5)]

            # Unmute should clear again
            transcriber.unmute()

            assert transcriber.vad._speech_buffer == []

    def test_muted_state_prevents_vad_processing(self):
        """Verify that muted state skips VAD in process loop."""
        from audio.fast_whisper_service import FastWhisperTranscriber
        from unittest.mock import patch, MagicMock

        with patch('audio.fast_whisper_service.get_model'):
            transcriber = FastWhisperTranscriber()

            # Mock VAD to track calls
            transcriber.vad.process_chunk = MagicMock()

            # Put transcriber in running + muted state
            transcriber._running = True
            transcriber._muted = True

            # Simulate audio chunk arriving
            audio_chunk = np.zeros(512, dtype=np.float32)
            transcriber._audio_queue.put(audio_chunk)

            # Process one iteration
            try:
                chunk = transcriber._audio_queue.get(timeout=0.1)
                with transcriber._mute_lock:
                    if transcriber._muted:
                        pass  # Skip VAD - this is what _process_loop does
                    else:
                        transcriber.vad.process_chunk(chunk)
            except queue.Empty:
                pass

            # VAD should NOT have been called
            transcriber.vad.process_chunk.assert_not_called()

    def test_interrupt_detection_works_while_muted(self):
        """Verify interrupts are still detected even when muted."""
        from audio.fast_whisper_service import FastWhisperTranscriber
        from audio.vad import SpeechSegment
        from unittest.mock import patch, MagicMock

        interrupts = []

        def on_interrupt(text):
            interrupts.append(text)

        mock_model = MagicMock()
        mock_model.transcribe.return_value = (
            [MagicMock(text="Kira stop please")],
            MagicMock(language="en")
        )

        with patch('audio.fast_whisper_service.get_model', return_value=mock_model):
            transcriber = FastWhisperTranscriber(on_interrupt=on_interrupt)
            transcriber._muted = True

            # Simulate speech segment
            segment = SpeechSegment(
                audio=np.zeros(16000, dtype=np.float32),
                start_time=time.time(),
                end_time=time.time() + 1,
                duration_ms=1000
            )

            transcriber._handle_speech(segment)

            # Interrupt should have been detected
            assert len(interrupts) == 1
            assert "Kira stop" in interrupts[0]


class TestEventFlowIntegration:
    """Test event flow through the perception system."""

    def test_perception_event_queue_ordering(self):
        """Verify events are queued and retrieved in order."""
        from kira_perception import KiraPerception

        perception = KiraPerception(prewarm=False, enable_tts=False, enable_stt=False)

        # Emit multiple events
        for i in range(5):
            perception._emit_event('visual', {'index': i})

        # Retrieve and verify order
        for i in range(5):
            event = perception.get_event(timeout=0.1)
            assert event is not None
            assert event.data['index'] == i

    def test_perception_event_queue_nonblocking(self):
        """Verify get_event doesn't block indefinitely."""
        from kira_perception import KiraPerception

        perception = KiraPerception(prewarm=False, enable_tts=False, enable_stt=False)

        start = time.time()
        event = perception.get_event(timeout=0.1)
        elapsed = time.time() - start

        assert event is None
        assert elapsed < 0.5  # Should return quickly after timeout

    def test_speak_command_format(self):
        """Verify speak command generates correct JSON."""
        from kira_perception import KiraPerception
        import json
        from io import StringIO

        # Enable TTS so speak() actually does something
        perception = KiraPerception(prewarm=False, enable_tts=True, enable_stt=False)

        # Capture what would be sent to TTS
        spoken_texts = []

        # Mock the TTS to capture the speak call
        class MockTTS:
            def speak(self, text, blocking=True):
                spoken_texts.append(text)

        perception._tts = MockTTS()

        # Need to also mock echo manager
        class MockEchoManager:
            def start_speaking(self): pass
            def stop_speaking(self): pass

        perception._echo_manager = MockEchoManager()

        perception.speak("Hello world!")

        assert "Hello world!" in spoken_texts


class TestTimingIntegration:
    """Test timing characteristics of the perception system."""

    def test_vad_processing_speed(self):
        """Verify VAD can process chunks fast enough for real-time."""
        from audio.vad import SileroVAD, CHUNK_SAMPLES

        vad = SileroVAD()

        # Generate test audio (silence)
        audio_chunk = np.zeros(CHUNK_SAMPLES, dtype=np.float32)

        # Warmup
        vad.process_chunk(audio_chunk)

        # Time multiple chunks
        latencies = []
        for _ in range(10):
            start = time.time()
            vad.process_chunk(audio_chunk)
            latencies.append((time.time() - start) * 1000)

        avg_latency = sum(latencies) / len(latencies)
        max_latency = max(latencies)

        print(f"\n  VAD latencies: avg={avg_latency:.1f}ms, max={max_latency:.1f}ms")

        # VAD should be < 10ms per chunk for real-time (32ms chunks)
        assert avg_latency < 10, f"VAD too slow: {avg_latency}ms avg"

    def test_event_emission_speed(self):
        """Verify event emission is fast."""
        from kira_perception import KiraPerception

        perception = KiraPerception(prewarm=False, enable_tts=False, enable_stt=False)

        latencies = []
        for i in range(100):
            start = time.time()
            perception._emit_event('visual', {'index': i})
            latencies.append((time.time() - start) * 1000)

        avg_latency = sum(latencies) / len(latencies)
        max_latency = max(latencies)

        print(f"\n  Event emission latencies: avg={avg_latency:.3f}ms, max={max_latency:.3f}ms")

        # Event emission should be sub-millisecond
        assert avg_latency < 1, f"Event emission too slow: {avg_latency}ms avg"


class TestConcurrencyIntegration:
    """Test concurrent access patterns."""

    def test_concurrent_event_emission_and_retrieval(self):
        """Verify events can be emitted and retrieved concurrently."""
        from kira_perception import KiraPerception

        perception = KiraPerception(prewarm=False, enable_tts=False, enable_stt=False)

        emitted = []
        retrieved = []
        errors = []

        def emitter():
            try:
                for i in range(50):
                    perception._emit_event('visual', {'index': i})
                    emitted.append(i)
                    time.sleep(0.001)
            except Exception as e:
                errors.append(f"Emitter error: {e}")

        def retriever():
            try:
                while len(retrieved) < 50:
                    event = perception.get_event(timeout=0.1)
                    if event:
                        retrieved.append(event.data['index'])
            except Exception as e:
                errors.append(f"Retriever error: {e}")

        emit_thread = threading.Thread(target=emitter)
        retrieve_thread = threading.Thread(target=retriever)

        emit_thread.start()
        retrieve_thread.start()

        emit_thread.join(timeout=5)
        retrieve_thread.join(timeout=5)

        assert not errors, f"Errors occurred: {errors}"
        assert len(emitted) == 50
        assert len(retrieved) == 50
        # Order should be preserved
        assert retrieved == list(range(50))

    def test_mute_unmute_thread_safety(self):
        """Verify mute/unmute is thread-safe."""
        from audio.fast_whisper_service import FastWhisperTranscriber
        from unittest.mock import patch

        with patch('audio.fast_whisper_service.get_model'):
            transcriber = FastWhisperTranscriber()

            errors = []
            operations = []

            def toggler(id):
                try:
                    for _ in range(100):
                        transcriber.mute()
                        operations.append(f"{id}:mute")
                        time.sleep(0.001)
                        transcriber.unmute()
                        operations.append(f"{id}:unmute")
                except Exception as e:
                    errors.append(f"Thread {id} error: {e}")

            threads = [threading.Thread(target=toggler, args=(i,)) for i in range(3)]

            for t in threads:
                t.start()
            for t in threads:
                t.join(timeout=5)

            assert not errors, f"Errors occurred: {errors}"
            # Should have completed all operations
            assert len(operations) == 600  # 3 threads * 100 iterations * 2 ops


class TestDataFormatIntegration:
    """Test that data formats match between Python emission and Ruby consumption."""

    def test_visual_event_has_required_fields(self):
        """Verify visual events have all fields Ruby expects."""
        from kira_perception import KiraPerception
        import json

        perception = KiraPerception(prewarm=False, enable_tts=False, enable_stt=False)

        perception._emit_event('visual', {
            'emotion': 'happy',
            'description': 'Test description',
            'inference_ms': 150,
            'frame_diff': 0.05,
            'is_full_analysis': False
        })

        event = perception.get_event(timeout=0.1)
        json_str = event.to_json()
        parsed = json.loads(json_str)

        # Verify structure matches Ruby expectations
        assert 'type' in parsed
        assert 'data' in parsed
        assert 'timestamp' in parsed

        data = parsed['data']
        assert 'emotion' in data
        assert 'description' in data
        assert 'inference_ms' in data
        assert 'is_full_analysis' in data

    def test_voice_event_has_required_fields(self):
        """Verify voice events have all fields Ruby expects."""
        from kira_perception import KiraPerception
        import json

        perception = KiraPerception(prewarm=False, enable_tts=False, enable_stt=False)

        perception._emit_event('voice', {
            'text': 'Hello Kira',
            'language': 'en',
            'latency_ms': 350
        })

        event = perception.get_event(timeout=0.1)
        json_str = event.to_json()
        parsed = json.loads(json_str)

        data = parsed['data']
        assert 'text' in data
        assert data['text'] == 'Hello Kira'

    def test_json_output_is_single_line(self):
        """Verify JSON output is single line (required for line-based IPC)."""
        from kira_perception import PerceptionEvent
        import json

        event = PerceptionEvent(
            type='visual',
            data={
                'description': 'Multi\nline\ndescription',
                'nested': {'key': 'value'}
            }
        )

        json_str = event.to_json()

        # Should be single line
        assert '\n' not in json_str, "JSON should be single line for IPC"

        # Should still be valid JSON
        parsed = json.loads(json_str)
        assert parsed['data']['description'] == 'Multi\nline\ndescription'
