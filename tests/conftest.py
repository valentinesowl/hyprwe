"""Shared pytest fixtures for the HWE test suite.

`scripts/` holds standalone tools, not an importable package — and one of them is
named with a hyphen (`render-theme.py`), which `import` cannot spell at all. So
we load each by file path and hand it back as a module object; the tests then
exercise real functions rather than shelling out and grepping stdout.
"""
import importlib.util
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
SCRIPTS = REPO / "scripts"
THEMES = REPO / "themes"
TEMPLATES = REPO / "templates"


def _load(stem: str):
    """Import scripts/<stem>.py as a module, whatever its filename looks like."""
    path = SCRIPTS / f"{stem}.py"
    name = f"hwe_{stem.replace('-', '_')}"
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    # Register before exec so a module that inspects sys.modules behaves as it
    # would under a normal import.
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture(scope="session")
def repo() -> Path:
    return REPO


@pytest.fixture(scope="session")
def templates_dir() -> Path:
    return TEMPLATES


@pytest.fixture(scope="session")
def render_theme():
    return _load("render-theme")


@pytest.fixture(scope="session")
def wbstat():
    return _load("wbstat")


@pytest.fixture(scope="session")
def genwall():
    return _load("genwall")


@pytest.fixture(scope="session")
def genpreview():
    return _load("genpreview")


@pytest.fixture(scope="session")
def wbmerge():
    return _load("wbmerge")


@pytest.fixture(scope="session")
def fontlock():
    return _load("fontlock")


def theme_paths() -> list[Path]:
    """Every shipped theme's theme.toml, sorted (used to parametrise tests)."""
    return sorted(THEMES.glob("*/theme.toml"))


def theme_ids() -> list[str]:
    return [p.parent.name for p in theme_paths()]


@pytest.fixture
def minimal_theme() -> dict:
    """A theme dict that satisfies the role contract with nothing to spare.

    Built from the contract itself rather than a copied palette, so adding a
    required role updates this fixture automatically instead of silently
    leaving it invalid.
    """
    rt = _load("render-theme")
    return {
        "name": "test-theme",
        "sem": {role: "#123456" for role in rt.REQUIRED_ROLES},
        "params": {},
        "font": {},
    }
