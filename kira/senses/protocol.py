"""
Kira Protocol - The stable contract between Core (Ruby) and Senses (Python).

All communication happens over JSON lines on stdin/stdout.
This protocol is versioned and should remain backwards compatible.
"""

from dataclasses import dataclass, field, asdict
from typing import Optional, Any, Union
import json
import sys
import time

PROTOCOL_VERSION = "1.0"

# Default priorities for signal types
PRIORITY_VOICE = 100  # User spoke - highest priority
PRIORITY_INTERRUPT = 90  # User wants to interrupt
PRIORITY_SCREEN = 50  # Screen content
PRIORITY_VISUAL = 30  # Camera observation
PRIORITY_SYSTEM = 10  # System events


@dataclass
class Signal:
    """
    Sense -> Core: Something was perceived.

    This is the primary message type for senses to communicate
    observations to the core orchestrator.
    """

    sense: str  # Which sense: "vision", "hearing", "screen"
    content: str  # Human-readable description of what was perceived
    priority: int  # Processing priority (higher = more urgent)
    metadata: dict = field(default_factory=dict)  # Sense-specific data
    timestamp: float = field(default_factory=time.time)

    def to_json(self) -> str:
        return json.dumps({"type": "signal", **asdict(self)})


@dataclass
class Status:
    """
    Sense -> Core: Lifecycle status update.

    Used to communicate sense state changes like ready, error, stopped.
    """

    sense: str  # Which sense
    status: str  # "ready", "error", "stopped", "busy"
    message: str = ""  # Optional details
    timestamp: float = field(default_factory=time.time)

    def to_json(self) -> str:
        return json.dumps({"type": "status", **asdict(self)})


@dataclass
class Command:
    """
    Core -> Sense: Instruction to perform an action.

    Commands control sense behavior: start, stop, configure, or
    trigger outputs like speech.
    """

    command: str  # "start", "stop", "configure", "speak", "interrupt"
    options: dict = field(default_factory=dict)  # Command-specific options

    @classmethod
    def from_json(cls, line: str) -> Optional["Command"]:
        """Parse a JSON line into a Command, or None if invalid."""
        try:
            data = json.loads(line)
            if data.get("type") == "command" or "command" in data:
                return cls(command=data["command"], options=data.get("options", {}))
        except (json.JSONDecodeError, KeyError):
            pass
        return None


def emit(message: Union[Signal, Status]) -> None:
    """Send a message to core via stdout."""
    print(message.to_json(), flush=True)


def emit_signal(sense: str, content: str, priority: int, **metadata) -> None:
    """Convenience: emit a signal."""
    emit(Signal(sense=sense, content=content, priority=priority, metadata=metadata))


def emit_status(sense: str, status: str, message: str = "") -> None:
    """Convenience: emit a status update."""
    emit(Status(sense=sense, status=status, message=message))


def emit_ready(sense: str) -> None:
    """Convenience: emit ready status."""
    emit_status(sense, "ready")


def emit_error(sense: str, message: str) -> None:
    """Convenience: emit error status."""
    emit_status(sense, "error", message)


def log(message: str) -> None:
    """Log to stderr (doesn't interfere with protocol on stdout)."""
    print(message, file=sys.stderr, flush=True)


def read_commands():
    """
    Generator that yields Commands from stdin.

    Usage:
        for cmd in read_commands():
            if cmd.command == "stop":
                break
            handle(cmd)
    """
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        cmd = Command.from_json(line)
        if cmd:
            yield cmd
