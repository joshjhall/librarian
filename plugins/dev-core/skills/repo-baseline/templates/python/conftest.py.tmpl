"""Shared fixtures: load a `bin/<name>.py` script as a module by path."""

import importlib.util
import sys
from pathlib import Path

import pytest

BIN_DIR = Path(__file__).resolve().parent.parent / "bin"


def _load(name):
    path = BIN_DIR / f"{name}.py"
    if not path.is_file():
        raise FileNotFoundError(f"no script at {path}")
    # Prefixed so a script named like a stdlib module (bin/json.py) cannot
    # replace the real one in sys.modules for the rest of the session.
    module_name = "bin_" + name.replace("-", "_")
    spec = importlib.util.spec_from_file_location(module_name, path)
    module = importlib.util.module_from_spec(spec)
    # Register before exec so dataclasses and pickling can resolve the module,
    # and unregister on failure so no half-initialized module is left behind.
    sys.modules[module_name] = module
    try:
        spec.loader.exec_module(module)
    except BaseException:
        sys.modules.pop(module_name, None)
        raise
    return module


@pytest.fixture
def load_script():
    """Return a loader: `load_script("rotate-logs")` -> the module object."""
    return _load
