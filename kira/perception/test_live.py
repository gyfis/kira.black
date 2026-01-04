#!/usr/bin/env python3
"""
Live test script for Kira perception components.

Usage:
    uv run python test_live.py vlm      # Test vision only
    uv run python test_live.py stt      # Test speech-to-text only  
    uv run python test_live.py tts      # Test text-to-speech only
    uv run python test_live.py all      # Test everything together
"""

import sys
import time

def test_vlm():
    """Test VLM with camera."""
    print("=" * 60)
    print("VLM TEST - Will describe what your camera sees")
    print("=" * 60)
    
    import cv2
    from vlm.moondream_service import MoondreamVLM
    
    cap = cv2.VideoCapture(0)
    if not cap.isOpened():
        print("ERROR: Could not open camera")
        print("Make sure you've granted camera permissions")
        return False
    
    print("Camera opened. Loading VLM model...")
    vlm = MoondreamVLM()
    
    print("\nCapturing frame and describing...")
    ret, frame = cap.read()
    if not ret:
        print("ERROR: Could not read frame")
        cap.release()
        return False
    
    frame_rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
    
    result = vlm.describe(frame_rgb)
    if result:
        print(f"\n[VLM] {result.description}")
        print(f"      (took {result.inference_ms}ms)")
    else:
        print("ERROR: VLM returned None")
        cap.release()
        return False
    
    cap.release()
    print("\nVLM test PASSED!")
    return True


def test_stt():
    """Test STT with microphone."""
    print("=" * 60)
    print("STT TEST - Will transcribe what you say")
    print("Say something, then wait for transcription")
    print("Press Ctrl+C to stop")
    print("=" * 60)
    
    sys.path.insert(0, '.')
    from audio.vad import VADTranscriptionPipeline
    
    results = []
    
    def on_text(result):
        print(f"\n[STT] {result['text']}")
        print(f"      (duration: {result['duration_ms']}ms, inference: {result['inference_ms']}ms)")
        results.append(result)
    
    pipeline = VADTranscriptionPipeline(
        whisper_model="base",
        on_transcription=on_text
    )
    
    print("\nStarting... speak now!")
    if not pipeline.start():
        print("ERROR: Could not start audio pipeline")
        return False
    
    try:
        # Wait for at least one transcription or timeout
        timeout = 30
        start = time.time()
        while time.time() - start < timeout:
            if results:
                break
            time.sleep(0.1)
        
        if not results:
            print(f"\nNo speech detected in {timeout} seconds")
    except KeyboardInterrupt:
        print("\nStopped by user")
    finally:
        pipeline.stop()
    
    if results:
        print("\nSTT test PASSED!")
        return True
    return False


def test_tts():
    """Test TTS - will speak a sentence."""
    print("=" * 60)
    print("TTS TEST - Will speak a sentence")
    print("=" * 60)
    
    from tts.chatterbox_service import ChatterboxTTS
    
    print("\nLoading TTS model (this may take a moment)...")
    tts = ChatterboxTTS()
    
    text = "Hello! I am Kira, your visual AI companion. Nice to meet you!"
    print(f"\nSpeaking: '{text}'")
    
    tts.speak(text, blocking=True)
    
    print("\nTTS test PASSED!")
    return True


def test_all():
    """Test all components together."""
    print("=" * 60)
    print("FULL TEST - Testing VLM, STT, and TTS together")
    print("=" * 60)
    
    from kira_perception import KiraPerception
    
    perception = KiraPerception(vlm_hz=0.5, enable_stt=True, enable_tts=True)
    
    print("\nStarting perception service...")
    if not perception.start():
        print("ERROR: Could not start perception")
        return False
    
    print("Perception started! Watching for events...")
    print("- Visual descriptions will appear when scene changes")
    print("- Speak to test STT")
    print("- Press Ctrl+C to stop")
    print("-" * 40)
    
    try:
        while True:
            event = perception.get_event(timeout=0.5)
            if event:
                print(f"\n[{event.type.upper()}] {event.data}")
    except KeyboardInterrupt:
        print("\nStopping...")
    finally:
        perception.stop()
    
    print("\nFull test completed!")
    return True


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    
    mode = sys.argv[1].lower()
    
    if mode == 'vlm':
        success = test_vlm()
    elif mode == 'stt':
        success = test_stt()
    elif mode == 'tts':
        success = test_tts()
    elif mode == 'all':
        success = test_all()
    else:
        print(f"Unknown mode: {mode}")
        print(__doc__)
        sys.exit(1)
    
    sys.exit(0 if success else 1)


if __name__ == '__main__':
    main()
