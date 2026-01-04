"""
Pytest configuration and shared fixtures for Kira perception tests.
"""

import pytest
import sys
from pathlib import Path

# Add parent directory to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent))


def pytest_configure(config):
    """Register custom markers."""
    config.addinivalue_line(
        "markers", "integration: marks tests as integration tests (require models/hardware)"
    )
    config.addinivalue_line(
        "markers", "slow: marks tests as slow (model loading)"
    )


def pytest_collection_modifyitems(config, items):
    """Skip integration tests by default unless explicitly requested."""
    if config.getoption("-m"):
        # User specified markers, don't modify
        return
    
    skip_integration = pytest.mark.skip(reason="use -m integration to run integration tests")
    for item in items:
        if "integration" in item.keywords:
            item.add_marker(skip_integration)
