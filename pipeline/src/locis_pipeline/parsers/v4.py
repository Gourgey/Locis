"""Adapter for D-TRO data specification v4.x.

v4.0.0 made condition nesting unambiguous: a regulation has either one
``condition`` or one ``conditionSet``; a conditionSet is an object with an
``operator`` and a ``conditions`` array whose items are conditions, each of which
may itself hold a nested ``conditionSet``.
"""

from __future__ import annotations

from .base import register_adapter
from .common import normalise_leaf, normalise_rate_table, unsupported, with_modifiers

_OPERATORS = {"and": "and", "or": "or", "xor": "xor"}


class V4Adapter:
    def regulation(self, provision: dict) -> dict | None:
        regulation = provision.get("regulation")
        return regulation if isinstance(regulation, dict) else None

    def condition_tree(self, regulation: dict) -> tuple[dict, list[str]]:
        has_condition = "condition" in regulation
        has_set = "conditionSet" in regulation
        if has_condition == has_set:
            return unsupported("regulation needs exactly one of condition/conditionSet"), []
        if has_condition:
            return self._condition(regulation["condition"]), []
        return self._condition_set(regulation["conditionSet"]), []

    def _condition(self, raw) -> dict:
        if not isinstance(raw, dict):
            return unsupported("condition is not an object")
        if "conditionSet" in raw:
            others = [k for k in raw if k not in ("conditionSet", "negate", "operator", "rateTable")]
            if others:
                return unsupported("condition mixes conditionSet with " + "+".join(sorted(others)))
            node = self._condition_set(raw["conditionSet"])
        else:
            node = normalise_leaf(raw)
        return with_modifiers(node, raw)

    def _condition_set(self, raw) -> dict:
        if not isinstance(raw, dict):
            return unsupported("conditionSet is not an object")
        operator = _OPERATORS.get(str(raw.get("operator", "")).lower())
        if operator is None:
            return unsupported(f"unknown operator {raw.get('operator')!r}")
        conditions = raw.get("conditions")
        if not isinstance(conditions, list) or not conditions:
            return unsupported("conditionSet has no conditions")
        node: dict = {"op": operator, "items": [self._condition(c) for c in conditions]}
        rate = normalise_rate_table(raw.get("rateTable"))
        if rate is not None:
            node["rate"] = rate
        return node


register_adapter(lambda version: version[0] == 4, V4Adapter())
