"""
Kira Senses - Pluggable perception modules.

Each sense is an independent process that communicates with the
Ruby core via the protocol defined in protocol.py.

To run a sense:
    python -m senses.vision
    python -m senses.hearing
    python -m senses.voice

To create a custom sense:
    1. Create a new module under senses/
    2. Subclass BaseSense or BaseOutput from senses.base
    3. Implement the required methods
    4. Create a __main__.py that calls sense.run()
"""

from .protocol import (
    Signal,
    Status,
    Command,
    emit,
    emit_signal,
    emit_status,
    emit_ready,
    emit_error,
    log,
    PRIORITY_VOICE,
    PRIORITY_VISUAL,
    PRIORITY_SCREEN,
    PRIORITY_INTERRUPT,
)
from .base import BaseSense, BaseOutput

__all__ = [
    "Signal",
    "Status",
    "Command",
    "emit",
    "emit_signal",
    "emit_status",
    "emit_ready",
    "emit_error",
    "log",
    "PRIORITY_VOICE",
    "PRIORITY_VISUAL",
    "PRIORITY_SCREEN",
    "PRIORITY_INTERRUPT",
    "BaseSense",
    "BaseOutput",
]
