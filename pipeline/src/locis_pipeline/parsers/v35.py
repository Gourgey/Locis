"""Adapter for D-TRO data specification v3.5.x (still accepted by the service).

Differences from v4 that matter here:

* ``regulation`` is an array holding one regulation;
* ``condition`` is an array holding one condition;
* ``conditionSet`` is an array of objects in which ``operator``, ``conditions``,
  ``condition`` and a nested ``conditionSet`` can all appear side by side.

DfT described that sibling layout as ambiguous, which is why v4 replaced it. This
adapter reads the layout the official v3.5 examples use (the operator joins every
sibling operand) and flags the feature with ``legacyConditionNesting`` so the app
caps its confidence. Shapes with no operator to join several operands are
unsupported.
"""

from __future__ import annotations

from .base import register_adapter
from .common import normalise_leaf, unsupported, with_modifiers

_OPERATORS = {"and": "and", "or": "or", "xor": "xor"}
_SET_KEYS = ("conditions", "condition", "conditionSet")


class V35Adapter:
    def regulation(self, provision: dict) -> dict | None:
        regulation = provision.get("regulation")
        if isinstance(regulation, list) and len(regulation) == 1 and isinstance(regulation[0], dict):
            return regulation[0]
        return None

    def condition_tree(self, regulation: dict) -> tuple[dict, list[str]]:
        has_condition = "condition" in regulation
        has_set = "conditionSet" in regulation
        if has_condition == has_set:
            return unsupported("regulation needs exactly one of condition/conditionSet"), []
        if has_condition:
            return self._single(regulation["condition"]), []
        issues: list[str] = []
        return self._set_array(regulation["conditionSet"], issues), issues

    def _single(self, raw) -> dict:
        if isinstance(raw, list):
            if len(raw) != 1:
                return unsupported("condition array does not hold exactly one condition")
            raw = raw[0]
        if not isinstance(raw, dict):
            return unsupported("condition is not an object")
        return with_modifiers(normalise_leaf(raw), raw)

    def _set_array(self, raw, issues: list[str]) -> dict:
        if not isinstance(raw, list) or not raw:
            return unsupported("conditionSet is empty")
        if len(raw) != 1:
            return unsupported("several conditionSets with no operator joining them")
        return self._set(raw[0], issues)

    def _set(self, raw, issues: list[str]) -> dict:
        if not isinstance(raw, dict):
            return unsupported("conditionSet entry is not an object")
        operator = _OPERATORS.get(str(raw.get("operator", "")).lower())
        if operator is None:
            return unsupported(f"unknown or missing operator {raw.get('operator')!r}")
        present = [k for k in _SET_KEYS if k in raw]
        if len(present) > 1:
            issues.append("legacyConditionNesting")
        items: list[dict] = []
        for entry in raw.get("conditions") or []:
            items.append(self._operand(entry, issues))
        if "condition" in raw:
            conditions = raw["condition"] if isinstance(raw["condition"], list) else [raw["condition"]]
            for entry in conditions:
                items.append(self._operand(entry, issues))
        nested = raw.get("conditionSet")
        if nested is not None:
            if not isinstance(nested, list):
                nested = [nested]
            for entry in nested:
                items.append(self._set(entry, issues))
        if not items:
            return unsupported("conditionSet has no operands")
        return {"op": operator, "items": items}

    def _operand(self, raw, issues: list[str]) -> dict:
        if not isinstance(raw, dict):
            return unsupported("condition is not an object")
        if any(k in raw for k in _SET_KEYS):
            leaf_keys = [k for k in raw if k not in _SET_KEYS + ("operator", "negate")]
            if leaf_keys:
                return unsupported("condition mixes a set with " + "+".join(sorted(leaf_keys)))
            if "operator" in raw:
                node = self._set(raw, issues)
            elif list(k for k in _SET_KEYS if k in raw) == ["conditionSet"]:
                node = self._set_array(raw["conditionSet"], issues)
            else:
                node = unsupported("nested conditions with no operator")
            return {"not": node} if raw.get("negate") is True else node
        return with_modifiers(normalise_leaf(raw), raw)


register_adapter(lambda version: version[:2] == (3, 5), V35Adapter())
