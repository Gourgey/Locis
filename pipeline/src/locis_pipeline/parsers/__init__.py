"""D-TRO record parsers. Import this package to register all schema adapters."""

from . import v4, v35  # noqa: F401  (registers adapters)
from .base import ParsedFeature, ParsedRecord, adapter_for, parse_record

__all__ = ["ParsedFeature", "ParsedRecord", "adapter_for", "parse_record"]
