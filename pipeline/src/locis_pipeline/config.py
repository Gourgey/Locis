"""Pipeline configuration, read from environment variables (see .env.example)."""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

# Greater London plus a small margin, as west,south,east,north in WGS84 degrees.
LONDON_BOUNDS = (-0.5104, 51.2868, 0.3340, 51.6919)
PRODUCTION_URL = "https://dtro.dft.gov.uk/v1"
INTEGRATION_URL = "https://dtro-integration.dft.gov.uk/v1"


@dataclass(frozen=True)
class Settings:
    base_url: str
    client_id: str | None
    client_secret: str | None
    db_path: Path
    out_dir: Path
    region: tuple[float, float, float, float] | None
    tile_zoom: int
    fixtures_dir: Path | None

    @property
    def has_credentials(self) -> bool:
        return bool(self.client_id and self.client_secret)


def load_dotenv(path: Path) -> None:
    """Minimal .env reader: KEY=VALUE lines, existing environment wins."""
    if not path.is_file():
        return
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


def _parse_region(text: str | None) -> tuple[float, float, float, float] | None:
    if text is None:
        return LONDON_BOUNDS
    if text.strip().lower() in ("", "none", "all", "national"):
        return None
    parts = [float(p) for p in text.split(",")]
    if len(parts) != 4 or parts[0] >= parts[2] or parts[1] >= parts[3]:
        raise ValueError("LOCIS_REGION must be west,south,east,north")
    return (parts[0], parts[1], parts[2], parts[3])


def pipeline_dir() -> Path:
    """The pipeline folder of a source checkout, else the current directory."""
    candidate = Path(__file__).resolve().parents[2]
    return candidate if (candidate / "pyproject.toml").is_file() else Path.cwd()


def load_settings(root: Path | None = None) -> Settings:
    """Read settings. Defaults do not depend on where the command is run from."""
    root = root or pipeline_dir()
    for candidate in (Path.cwd() / ".env", root / ".env", root.parent / ".env"):
        load_dotenv(candidate)
    env = os.environ
    fixtures = env.get("LOCIS_FIXTURES_DIR")
    return Settings(
        base_url=env.get("DTRO_BASE_URL", PRODUCTION_URL).rstrip("/"),
        client_id=env.get("DTRO_CLIENT_ID") or None,
        client_secret=env.get("DTRO_CLIENT_SECRET") or None,
        db_path=Path(env.get("LOCIS_DB", str(root / "var" / "locis.sqlite"))),
        out_dir=Path(env.get("LOCIS_OUT", str(root / "dist"))),
        region=_parse_region(env.get("LOCIS_REGION")),
        tile_zoom=int(env.get("LOCIS_TILE_ZOOM", "15")),
        fixtures_dir=Path(fixtures) if fixtures else None,
    )
