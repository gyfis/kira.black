"""
Base classes for Kira senses and outputs.

To create a new sense:
1. Subclass BaseSense
2. Implement _start(), _stop(), and _configure()
3. Call self.emit_signal() when you perceive something
4. Create a __main__.py that calls sense.run()

Example:
    class MySense(BaseSense):
        name = "my_sense"
        default_priority = 50

        def _start(self):
            self.thread = Thread(target=self._perception_loop)
            self.thread.start()

        def _perception_loop(self):
            while self.running:
                observation = perceive_something()
                self.emit_signal(observation)
"""

from abc import ABC, abstractmethod
import threading
import signal
import sys
from typing import Optional

# Handle imports for both package and direct execution
try:
    from .protocol import (
        Signal,
        Status,
        Command,
        emit,
        emit_ready,
        emit_error,
        emit_status,
        log,
        read_commands,
        PRIORITY_VISUAL,
        PRIORITY_VOICE,
    )
except ImportError:
    from protocol import (
        Signal,
        Status,
        Command,
        emit,
        emit_ready,
        emit_error,
        emit_status,
        log,
        read_commands,
        PRIORITY_VISUAL,
        PRIORITY_VOICE,
    )


class BaseSense(ABC):
    """
    Base class for all Kira senses (input plugins).

    A sense perceives something (camera, microphone, screen) and emits
    signals to the core orchestrator.
    """

    name: str = "base"  # Override in subclass
    default_priority: int = PRIORITY_VISUAL  # Override in subclass

    def __init__(self):
        self.running = False
        self._config = {}
        self._lock = threading.Lock()

    def run(self):
        """
        Main entry point. Call this from __main__.py.

        Handles the command loop and lifecycle.
        """
        # Handle SIGTERM/SIGINT gracefully
        signal.signal(signal.SIGTERM, self._handle_shutdown)
        signal.signal(signal.SIGINT, self._handle_shutdown)

        log(f"[{self.name}] Sense starting...")

        try:
            # Initialize (load models, etc.)
            self._initialize()
            emit_ready(self.name)

            # Process commands from core
            for cmd in read_commands():
                self._handle_command(cmd)
                if not self.running and cmd.command == "stop":
                    break

        except Exception as e:
            emit_error(self.name, str(e))
            raise
        finally:
            self._cleanup()
            emit_status(self.name, "stopped")
            log(f"[{self.name}] Sense stopped")

    def emit_signal(self, content: str, priority: Optional[int] = None, **metadata):
        """Emit a signal to core. Call this when you perceive something."""
        sig = Signal(
            sense=self.name,
            content=content,
            priority=priority or self.default_priority,
            metadata=metadata,
        )
        emit(sig)

    def configure(self, **options):
        """Update configuration. Can be called at runtime."""
        with self._lock:
            self._config.update(options)
            self._configure(options)

    # --- Override these in subclasses ---

    def _initialize(self):
        """Called once at startup. Load models, initialize hardware, etc."""
        pass

    @abstractmethod
    def _start(self):
        """Start perceiving. Called when core sends 'start' command."""
        pass

    @abstractmethod
    def _stop(self):
        """Stop perceiving. Called when core sends 'stop' command."""
        pass

    def _configure(self, options: dict):
        """Handle configuration changes. Called when core sends 'configure' command."""
        pass

    def _cleanup(self):
        """Called on shutdown. Release resources."""
        pass

    # --- Internal ---

    def _handle_command(self, cmd: Command):
        """Route commands to appropriate handlers."""
        log(f"[{self.name}] Command: {cmd.command}")

        if cmd.command == "start":
            if not self.running:
                self.running = True
                self._start()

        elif cmd.command == "stop":
            if self.running:
                self.running = False
                self._stop()

        elif cmd.command == "configure":
            self.configure(**cmd.options)

        else:
            log(f"[{self.name}] Unknown command: {cmd.command}")

    def _handle_shutdown(self, signum, frame):
        """Handle SIGTERM/SIGINT."""
        log(f"[{self.name}] Shutdown signal received")
        self.running = False
        self._stop()
        sys.exit(0)


class BaseOutput(ABC):
    """
    Base class for Kira outputs (output plugins).

    An output produces something (speech, display) based on
    commands from core.
    """

    name: str = "base_output"

    def __init__(self):
        self.running = False
        self._config = {}
        self._lock = threading.Lock()

    def run(self):
        """Main entry point."""
        signal.signal(signal.SIGTERM, self._handle_shutdown)
        signal.signal(signal.SIGINT, self._handle_shutdown)

        log(f"[{self.name}] Output starting...")

        try:
            self._initialize()
            emit_ready(self.name)
            self.running = True

            for cmd in read_commands():
                self._handle_command(cmd)
                if cmd.command == "stop":
                    break

        except Exception as e:
            emit_error(self.name, str(e))
            raise
        finally:
            self._cleanup()
            emit_status(self.name, "stopped")

    # --- Override these ---

    def _initialize(self):
        """Load models, initialize hardware."""
        pass

    @abstractmethod
    def _output(self, content: str, **options):
        """Produce output (speak, display, etc.)."""
        pass

    def _interrupt(self):
        """Interrupt current output."""
        pass

    def _configure(self, options: dict):
        """Handle configuration."""
        pass

    def _cleanup(self):
        """Release resources."""
        pass

    # --- Internal ---

    def _handle_command(self, cmd: Command):
        if cmd.command == "speak" or cmd.command == "output":
            text = cmd.options.get("text", "")
            if text:
                self._output(text, **cmd.options)

        elif cmd.command == "interrupt":
            self._interrupt()

        elif cmd.command == "configure":
            with self._lock:
                self._config.update(cmd.options)
                self._configure(cmd.options)

        elif cmd.command == "stop":
            self.running = False

        else:
            log(f"[{self.name}] Unknown command: {cmd.command}")

    def _handle_shutdown(self, signum, frame):
        self.running = False
        sys.exit(0)
