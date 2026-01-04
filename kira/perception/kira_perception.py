#!/usr/bin/env python3
"""
Kira Perception Service

Unified entry point that runs:
- Camera capture
- VLM (Moondream) at 2Hz
- STT (Whisper) for voice input
- TTS (Chatterbox) for voice output

Communicates with Ruby orchestrator via Unix socket or stdin/stdout.
"""

import sys
import json
import signal
import threading
import queue
import time
from dataclasses import dataclass, asdict
from typing import Optional
import numpy as np

# Will be lazily imported
cv2 = None


@dataclass
class PerceptionEvent:
    type: str  # 'visual', 'voice', 'ready', 'error'
    data: dict
    timestamp: float = None

    def __post_init__(self):
        if self.timestamp is None:
            self.timestamp = time.time()

    def to_json(self) -> str:
        return json.dumps(asdict(self))


class KiraPerception:
    """Main perception service coordinating all inputs."""

    # Default to 2Hz - fast VLM runs in ~400ms so we can achieve this rate
    def __init__(
        self,
        vlm_hz: float = 2.0,
        enable_tts: bool = True,
        enable_stt: bool = True,
        prewarm: bool = True,
    ):
        self.vlm_hz = vlm_hz
        self.enable_tts = enable_tts
        self.enable_stt = enable_stt
        self.prewarm = prewarm

        self._running = False
        self._event_queue = queue.Queue()

        # Components (lazy loaded)
        self._camera = None
        self._vlm = None
        self._stt = None
        self._tts = None
        self._echo_manager = None
        self._interruptable_transcriber = None
        self._warmed_up = False

    def warmup(self):
        """Pre-load all models to avoid first-call latency."""
        if self._warmed_up:
            return

        print("Warming up models...", file=sys.stderr)
        t0 = time.time()

        # Warmup VLM (biggest model, most important to prewarm)
        try:
            from vlm.fast_vlm_service import get_model as get_vlm_model

            get_vlm_model()
            print("  VLM: ready", file=sys.stderr)
        except Exception as e:
            print(f"  VLM warmup failed: {e}", file=sys.stderr)

        # Warmup STT if enabled
        if self.enable_stt:
            try:
                from audio.fast_whisper_service import get_model as get_whisper_model

                get_whisper_model("base")
                print("  STT: ready", file=sys.stderr)
            except Exception as e:
                print(f"  STT warmup failed: {e}", file=sys.stderr)

        # Warmup TTS if enabled
        if self.enable_tts:
            try:
                from tts.piper_service import get_voice

                get_voice()
                print("  TTS: ready", file=sys.stderr)
            except Exception as e:
                print(f"  TTS warmup failed: {e}", file=sys.stderr)

        elapsed = time.time() - t0
        print(f"Models warmed up in {elapsed:.1f}s", file=sys.stderr)
        self._warmed_up = True

    def start(self):
        """Start all perception services."""
        global cv2
        import cv2 as _cv2

        cv2 = _cv2

        # Pre-warm models if enabled
        if self.prewarm:
            self.warmup()

        self._running = True

        # Start camera
        self._camera = cv2.VideoCapture(0)
        if not self._camera.isOpened():
            self._emit_event("error", {"message": "Failed to open camera"})
            return False

        # Set camera properties
        self._camera.set(cv2.CAP_PROP_FRAME_WIDTH, 1280)
        self._camera.set(cv2.CAP_PROP_FRAME_HEIGHT, 720)
        self._camera.set(cv2.CAP_PROP_FPS, 30)

        # Start VLM thread
        self._vlm_thread = threading.Thread(target=self._vlm_loop, daemon=True)
        self._vlm_thread.start()

        # Start STT if enabled
        if self.enable_stt:
            self._stt_thread = threading.Thread(target=self._stt_loop, daemon=True)
            self._stt_thread.start()

        self._emit_event(
            "ready",
            {
                "camera": True,
                "vlm_hz": self.vlm_hz,
                "stt": self.enable_stt,
                "tts": self.enable_tts,
                "prewarm": self._warmed_up,
            },
        )

        return True

    def stop(self):
        """Stop all perception services."""
        self._running = False

        if self._camera:
            self._camera.release()

    def speak(self, text: str):
        """Speak text using TTS with echo cancellation."""
        if not self.enable_tts:
            return

        try:
            # Lazy load TTS - use fast Piper by default
            if self._tts is None:
                try:
                    from tts.piper_service import PiperTTS

                    self._tts = PiperTTS()
                    print("Using Piper TTS (fast)", file=sys.stderr)
                except Exception as e:
                    print(
                        f"Piper not available ({e}), falling back to Chatterbox",
                        file=sys.stderr,
                    )
                    from tts.chatterbox_service import ChatterboxTTS

                    self._tts = ChatterboxTTS()

            if self._echo_manager is None:
                from audio.echo_cancellation import EchoCancellationManager, AudioState

                self._echo_manager = EchoCancellationManager(
                    on_state_change=self._on_audio_state_change
                )

            # Start echo cancellation (mute mic)
            self._echo_manager.start_speaking()

            # Mute the interruptable transcriber (but still detect interrupts)
            if self._interruptable_transcriber:
                self._interruptable_transcriber.mute()

            try:
                self._tts.speak(text, blocking=True)
                # Small delay to let audio system settle before unmuting
                time.sleep(0.3)
            finally:
                # Stop echo cancellation (unmute mic)
                self._echo_manager.stop_speaking()
                if self._interruptable_transcriber:
                    self._interruptable_transcriber.unmute()

        except Exception as e:
            print(f"TTS error: {e}", file=sys.stderr)
            # Fallback to macOS say
            import subprocess

            subprocess.Popen(["say", "-v", "Samantha", text])

    def interrupt_speech(self):
        """Stop current TTS playback immediately."""
        if self._tts:
            self._tts.interrupt()
        if self._echo_manager:
            self._echo_manager.stop_speaking()
        if self._interruptable_transcriber:
            self._interruptable_transcriber.unmute()
        self._emit_event("speech_interrupted", {})

    def _on_audio_state_change(self, state):
        """Handle audio state changes."""
        from audio.echo_cancellation import AudioState

        self._emit_event("audio_state", {"state": state.name})

    def get_event(self, timeout: float = 0.1) -> Optional[PerceptionEvent]:
        """Get next perception event."""
        try:
            return self._event_queue.get(timeout=timeout)
        except queue.Empty:
            return None

    def _emit_event(self, event_type: str, data: dict):
        """Emit a perception event."""
        event = PerceptionEvent(type=event_type, data=data)
        self._event_queue.put(event)

    def _vlm_loop(self):
        """VLM processing loop with fast emotion + parallel full analysis."""
        from vlm.fast_vlm_service import FastVLM
        from vlm.frame_diff import FrameDifferencer
        from concurrent.futures import ThreadPoolExecutor

        vlm = FastVLM()
        differ = FrameDifferencer(
            change_threshold=0.05,
            min_frames_between_vlm=15,
        )

        frame_count = 0
        vlm_count = 0
        full_analysis_interval = 30  # Full analysis every 30 VLM calls (~15s at 2Hz)

        # Background executor for full analysis (single thread to avoid model contention)
        executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="vlm_full")
        pending_full_analysis = None
        last_full_description = None

        def run_full_analysis(frame_rgb_copy, count):
            """Run full analysis in background thread."""
            try:
                result = vlm.analyze(frame_rgb_copy, include_activity=True)
                if result:
                    return result.summary, result.inference_ms
            except Exception as e:
                print(f"Full VLM error: {e}", file=sys.stderr)
            return None, 0

        while self._running:
            # Check if background full analysis completed
            if pending_full_analysis is not None and pending_full_analysis.done():
                try:
                    desc, ms = pending_full_analysis.result()
                    if desc:
                        last_full_description = desc
                        print(
                            f"VLM [bg] FULL: {desc[:60]}... ({ms}ms)", file=sys.stderr
                        )
                        self._emit_event(
                            "visual_full",
                            {
                                "description": desc,
                                "inference_ms": ms,
                                "is_full_analysis": True,
                            },
                        )
                except Exception as e:
                    print(f"Full analysis result error: {e}", file=sys.stderr)
                pending_full_analysis = None

            # Capture frame
            ret, frame = self._camera.read()
            if not ret:
                print("Failed to read camera frame", file=sys.stderr)
                time.sleep(0.1)
                continue

            frame_count += 1
            frame_rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)

            # Check if we should run VLM
            should_run, diff_result = differ.should_run_vlm(frame_rgb)

            if not should_run:
                time.sleep(0.033)  # ~30fps capture rate
                continue

            vlm_count += 1

            try:
                # Always run quick emotion (fast path)
                t0 = time.time()
                result = vlm.analyze(frame_rgb, include_activity=False)

                if result is None:
                    print("VLM returned None", file=sys.stderr)
                    continue

                # Schedule full analysis in background if due and not already running
                # Skip vlm_count==1 to let the model warm up first with quick calls
                should_do_full = (vlm_count % full_analysis_interval == 0) or (
                    vlm_count == 2
                )
                if should_do_full and pending_full_analysis is None:
                    # Copy frame for background thread
                    frame_copy = frame_rgb.copy()
                    pending_full_analysis = executor.submit(
                        run_full_analysis, frame_copy, vlm_count
                    )
                    print(
                        f"VLM [{vlm_count}] scheduled FULL analysis in background",
                        file=sys.stderr,
                    )

                savings = (1 - vlm_count / frame_count) * 100 if frame_count > 0 else 0
                print(
                    f"VLM [{vlm_count}] quick: emotion={result.emotion} ({result.inference_ms}ms, {savings:.0f}% saved)",
                    file=sys.stderr,
                )

                self._emit_event(
                    "visual",
                    {
                        "emotion": result.emotion,
                        "description": last_full_description or result.emotion,
                        "inference_ms": result.inference_ms,
                        "frame_diff": diff_result.diff_score,
                        "is_full_analysis": False,
                    },
                )

            except Exception as e:
                print(f"VLM error: {e}", file=sys.stderr)
                import traceback

                traceback.print_exc()

        # Cleanup
        executor.shutdown(wait=False)

    def _stt_loop(self):
        """STT processing loop with interrupt detection using faster-whisper."""
        from audio.fast_whisper_service import FastWhisperTranscriber

        def on_transcription(result):
            self._emit_event(
                "voice",
                {
                    "text": result.text,
                    "language": result.language,
                    "latency_ms": result.duration_ms,
                },
            )

        def on_interrupt(text):
            """Handle interrupt keyword detection."""
            self._emit_event("interrupt", {"text": text})
            self.interrupt_speech()

        self._interruptable_transcriber = FastWhisperTranscriber(
            model_size="base",  # Can use "tiny" for even faster (~200ms)
            on_transcription=on_transcription,
            on_interrupt=on_interrupt,
        )

        if not self._interruptable_transcriber.start():
            self._emit_event("error", {"message": "Failed to start STT"})
            return

        while self._running:
            time.sleep(0.1)

        self._interruptable_transcriber.stop()


def run_service():
    """Run as a JSON-line service communicating via stdin/stdout."""
    # Use 2Hz - fast VLM runs in ~400ms
    perception = KiraPerception(vlm_hz=2.0)

    def signal_handler(signum, frame):
        perception.stop()
        sys.exit(0)

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    if not perception.start():
        sys.exit(1)

    # Output thread - send events to stdout
    def output_loop():
        while perception._running:
            event = perception.get_event(timeout=0.1)
            if event:
                print(event.to_json(), flush=True)

    output_thread = threading.Thread(target=output_loop, daemon=True)
    output_thread.start()

    # Input thread - receive commands from stdin
    for line in sys.stdin:
        try:
            cmd = json.loads(line.strip())
            command = cmd.get("command")

            if command == "speak":
                # Run speak in a thread to not block command processing
                text = cmd.get("text", "")
                threading.Thread(
                    target=perception.speak, args=(text,), daemon=True
                ).start()
            elif command == "interrupt":
                perception.interrupt_speech()
            elif command == "stop":
                break

        except json.JSONDecodeError:
            pass
        except Exception as e:
            print(
                json.dumps(
                    {
                        "type": "error",
                        "data": {"message": str(e)},
                        "timestamp": time.time(),
                    }
                ),
                flush=True,
            )

    perception.stop()


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--test":
        # Quick test mode
        perception = KiraPerception(vlm_hz=1.0, enable_stt=False)

        if perception.start():
            print("Perception started. Press Ctrl+C to stop.")

            try:
                while True:
                    event = perception.get_event(timeout=1.0)
                    if event:
                        print(f"[{event.type}] {event.data}")
            except KeyboardInterrupt:
                pass
            finally:
                perception.stop()
    else:
        run_service()
