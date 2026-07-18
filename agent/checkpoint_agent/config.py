from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

from dotenv import load_dotenv


def _repository_roots() -> list[Path]:
    """Return CHECKPOINT development roots without trusting an arbitrary cwd dotenv."""

    roots: list[Path] = []
    starts = (Path.cwd().resolve(), Path(__file__).resolve())
    for start in starts:
        for candidate in (start, *start.parents):
            if not (
                (candidate / "agent" / "pyproject.toml").is_file()
                and (candidate / "scripts" / "run-helper.sh").is_file()
            ):
                continue
            if candidate not in roots:
                roots.append(candidate)
            break
    return roots


def _load_operator_environment(roots: list[Path] | None = None) -> None:
    """Load ignored operator files once, with a documented non-secret precedence.

    Existing process values always win. For the hackathon checkout, the preferred
    root ``.env.local`` wins over the legacy ``scripts/.env.local``; root ``.env``
    is the final fallback. ``python-dotenv`` is deliberately left in quiet mode so
    neither paths nor credential values are emitted by the helper.
    """

    def normalize_bright_data_alias() -> None:
        canonical_bright_key = (os.getenv("BRIGHT_DATA_API_KEY") or "").strip()
        legacy_bright_key = (os.getenv("BRIGHTDATA_API_KEY") or "").strip()
        if not canonical_bright_key and legacy_bright_key:
            os.environ["BRIGHT_DATA_API_KEY"] = legacy_bright_key

    # A spelling supplied by the parent process has the same top precedence as
    # the canonical spelling.
    normalize_bright_data_alias()
    seen: set[Path] = set()
    for root in roots if roots is not None else _repository_roots():
        for candidate in (
            root / ".env.local",
            root / "scripts" / ".env.local",
            root / ".env",
        ):
            resolved = candidate.resolve()
            if resolved in seen or not resolved.is_file():
                continue
            seen.add(resolved)
            load_dotenv(dotenv_path=resolved, override=False, verbose=False)
            # Normalize before reading the next, lower-precedence file. This
            # makes precedence independent of which accepted spelling it used.
            normalize_bright_data_alias()


@dataclass(frozen=True)
class Settings:
    data_dir: Path
    database_path: Path
    host: str = "127.0.0.1"
    port: int = 8765
    bearer_token: str | None = None

    @classmethod
    def from_environment(cls) -> "Settings":
        _load_operator_environment()
        default_database = (
            Path.home()
            / "Library"
            / "Application Support"
            / "Checkpoint"
            / "checkpoint.sqlite"
        )
        configured_data_dir = (os.getenv("CHECKPOINT_DATA_DIR") or "").strip()
        data_dir = Path(configured_data_dir or default_database.parent).expanduser()
        configured_database = (os.getenv("CHECKPOINT_DATABASE_PATH") or "").strip()
        database_path = Path(
            configured_database or (data_dir / "checkpoint.sqlite")
        ).expanduser()
        configured_port = (os.getenv("CHECKPOINT_PORT") or "").strip()
        return cls(
            data_dir=data_dir,
            database_path=database_path,
            # The host is deliberately not configurable: this server is never public.
            host="127.0.0.1",
            port=int(configured_port or "8765"),
            bearer_token=(
                os.getenv("CHECKPOINT_CONTROL_TOKEN")
                or os.getenv("CHECKPOINT_BEARER_TOKEN")
                or None
            ),
        )
