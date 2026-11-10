"""Shared Python primitives for the litellm-auto-router-suite.

The distribution surface here is intentionally minimal: content packages (LiteLLM
plugins, headroom service clients) land as sibling uv workspace members and import
identity helpers from this package.
"""

__version__ = "0.1.0"

__all__ = ["__version__"]
