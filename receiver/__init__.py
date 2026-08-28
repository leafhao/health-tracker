"""Personal Apple Health receiver."""

from typing import Any


def create_app(*args: Any, **kwargs: Any) -> Any:
    """Load the FastAPI factory lazily so ``python -m receiver.worker`` is clean."""
    from .app import create_app as factory

    return factory(*args, **kwargs)


__all__ = ["create_app"]
