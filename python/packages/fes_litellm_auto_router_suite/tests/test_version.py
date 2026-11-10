"""Version-identity invariants for the seed package.

These assertions are genuine invariants, not tautologies: a release bump that edits
``pyproject.toml`` but forgets ``__init__.py`` (or the reverse) fails here, and a
malformed version string fails the semver check.
"""

import re
import tomllib
from pathlib import Path

from fes_litellm_auto_router_suite import __version__


def test_version_matches_pyproject() -> None:
    pyproject = Path(__file__).resolve().parent.parent / "pyproject.toml"
    with pyproject.open("rb") as handle:
        data = tomllib.load(handle)
    assert __version__ == data["project"]["version"]


def test_version_is_semver() -> None:
    assert re.match(r"^\d+\.\d+\.\d+$", __version__)
