import json
from pathlib import Path

import pytest

FIXTURES = Path(__file__).parent / "fixtures"
OFFICIAL = FIXTURES / "dtro_v4"


def official(name: str) -> dict:
    """Load one of DfT's published v4.0.0 example payloads as a record envelope."""
    envelope = json.loads((OFFICIAL / f"D-TRO-v4.0.0-example-{name}.json").read_text())
    envelope["id"] = f"official-{name}"
    return envelope


@pytest.fixture
def store():
    from locis_pipeline.store import Store

    s = Store(":memory:")
    yield s
    s.close()
