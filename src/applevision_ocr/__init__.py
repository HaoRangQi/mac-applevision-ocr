"""applevision-ocr: local OCR for macOS, powered by the Vision framework."""

__version__ = "1.0.0"

from .engine import EngineNotFound, find_engine, group_pages, run
from .fixes import fix_text
from .layout import LayoutOptions, layout
from .voting import vote, vote_line

__all__ = [
    "__version__",
    "EngineNotFound",
    "find_engine",
    "group_pages",
    "run",
    "fix_text",
    "LayoutOptions",
    "layout",
    "vote",
    "vote_line",
]
