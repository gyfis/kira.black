"""
Echo Cancellation for Kira.

Prevents Kira from hearing herself when speaking via TTS.

Two approaches:
1. Simple: Mute mic during TTS playback (implemented here)
2. Advanced: macOS AudioUnit VoiceProcessingIO (requires native code)

The simple approach works well for most cases. The main limitation is that
it blocks user interrupts during TTS - we mitigate this by periodically
unmuting briefly to check for interrupt keywords.
"""

import sys
import threading
import time
from typing import Optional, Callable
from enum import Enum, auto


class AudioState(Enum):
    """Current audio system state."""
    LISTENING = auto()      # Mic active, ready for input
    SPEAKING = auto()       # TTS playing, mic muted
    INTERRUPT_CHECK = auto() # Brief mic unmute to check for interrupts


class EchoCancellationManager:
    """
    Manages mic muting during TTS playback to prevent echo.
    
    While Kira is speaking:
    - Mic is muted most of the time
    - Periodically unmutes briefly to check for interrupt keywords
    - If interrupt detected, stops TTS and returns to listening
    """
    
    def __init__(
        self,
        interrupt_check_interval_ms: int = 500,
        interrupt_check_duration_ms: int = 100,
        on_state_change: Optional[Callable[[AudioState], None]] = None
    ):
        """
        Initialize echo cancellation manager.
        
        Args:
            interrupt_check_interval_ms: How often to check for interrupts during TTS
            interrupt_check_duration_ms: How long to listen during interrupt check
            on_state_change: Callback when audio state changes
        """
        self.interrupt_check_interval = interrupt_check_interval_ms / 1000
        self.interrupt_check_duration = interrupt_check_duration_ms / 1000
        self.on_state_change = on_state_change
        
        self._state = AudioState.LISTENING
        self._state_lock = threading.Lock()
        self._interrupt_thread: Optional[threading.Thread] = None
        self._stop_interrupt_checks = threading.Event()
    
    @property
    def state(self) -> AudioState:
        """Current audio state."""
        with self._state_lock:
            return self._state
    
    @property
    def is_mic_active(self) -> bool:
        """Whether mic should be capturing audio."""
        state = self.state
        return state in (AudioState.LISTENING, AudioState.INTERRUPT_CHECK)
    
    def start_speaking(self):
        """
        Called when TTS starts playing.
        
        Mutes mic and starts periodic interrupt checks.
        """
        with self._state_lock:
            if self._state == AudioState.SPEAKING:
                return
            self._state = AudioState.SPEAKING
        
        self._notify_state_change(AudioState.SPEAKING)
        
        # Start interrupt check thread
        self._stop_interrupt_checks.clear()
        self._interrupt_thread = threading.Thread(
            target=self._interrupt_check_loop,
            daemon=True
        )
        self._interrupt_thread.start()
    
    def stop_speaking(self):
        """
        Called when TTS stops playing.
        
        Returns to normal listening mode.
        """
        # Stop interrupt checks
        self._stop_interrupt_checks.set()
        if self._interrupt_thread:
            self._interrupt_thread.join(timeout=1)
            self._interrupt_thread = None
        
        with self._state_lock:
            self._state = AudioState.LISTENING
        
        self._notify_state_change(AudioState.LISTENING)
    
    def _interrupt_check_loop(self):
        """Periodically unmute to check for interrupt keywords."""
        while not self._stop_interrupt_checks.is_set():
            # Wait for interval
            if self._stop_interrupt_checks.wait(timeout=self.interrupt_check_interval):
                break  # Stop requested
            
            # Brief unmute for interrupt check
            with self._state_lock:
                if self._state != AudioState.SPEAKING:
                    break
                self._state = AudioState.INTERRUPT_CHECK
            
            self._notify_state_change(AudioState.INTERRUPT_CHECK)
            
            # Listen briefly
            time.sleep(self.interrupt_check_duration)
            
            # Return to muted state
            with self._state_lock:
                if self._state == AudioState.INTERRUPT_CHECK:
                    self._state = AudioState.SPEAKING
            
            self._notify_state_change(AudioState.SPEAKING)
    
    def _notify_state_change(self, state: AudioState):
        """Notify listener of state change."""
        if self.on_state_change:
            try:
                self.on_state_change(state)
            except Exception as e:
                print(f"State change callback error: {e}", file=sys.stderr)


class SimpleEchoCancellation:
    """
    Simple echo cancellation that fully mutes mic during TTS.
    
    Use this when you don't need interrupt detection during speech.
    """
    
    def __init__(self):
        self._muted = False
        self._lock = threading.Lock()
    
    @property
    def is_muted(self) -> bool:
        with self._lock:
            return self._muted
    
    def mute(self):
        """Mute mic (TTS starting)."""
        with self._lock:
            self._muted = True
    
    def unmute(self):
        """Unmute mic (TTS finished)."""
        with self._lock:
            self._muted = False


if __name__ == '__main__':
    # Demo
    def on_state(state):
        print(f"Audio state: {state.name}")
    
    manager = EchoCancellationManager(
        interrupt_check_interval_ms=1000,
        interrupt_check_duration_ms=200,
        on_state_change=on_state
    )
    
    print("Simulating TTS playback...")
    manager.start_speaking()
    
    time.sleep(5)  # Simulate 5 seconds of TTS
    
    print("TTS finished")
    manager.stop_speaking()
    
    print("Done")
