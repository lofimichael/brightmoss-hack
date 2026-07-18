import os
from pathlib import Path

from checkpoint_agent.config import Settings, _load_operator_environment


def test_blank_path_and_port_values_use_safe_defaults(monkeypatch) -> None:
    monkeypatch.setenv("CHECKPOINT_DATA_DIR", "  ")
    monkeypatch.setenv("CHECKPOINT_DATABASE_PATH", "")
    monkeypatch.setenv("CHECKPOINT_PORT", "")

    settings = Settings.from_environment()

    expected_data_dir = Path.home() / "Library" / "Application Support" / "Checkpoint"
    assert settings.data_dir == expected_data_dir
    assert settings.database_path == expected_data_dir / "checkpoint.sqlite"
    assert settings.port == 8765


def test_operator_dotenv_precedence_is_process_then_root_local_then_legacy_then_env(
    monkeypatch, tmp_path: Path
) -> None:
    scripts = tmp_path / "scripts"
    scripts.mkdir()
    (tmp_path / ".env").write_text(
        "CHECKPOINT_PRECEDENCE=env\nCHECKPOINT_ENV_ONLY=env-only\n",
        encoding="utf-8",
    )
    (scripts / ".env.local").write_text(
        "CHECKPOINT_PRECEDENCE=legacy\nCHECKPOINT_LEGACY_ONLY=legacy-only\n",
        encoding="utf-8",
    )
    (tmp_path / ".env.local").write_text(
        "CHECKPOINT_PRECEDENCE=root-local\nCHECKPOINT_LOCAL_ONLY=local-only\n",
        encoding="utf-8",
    )
    monkeypatch.setenv("CHECKPOINT_PROCESS_WINS", "process")
    monkeypatch.setenv("CHECKPOINT_PRECEDENCE", "process-wins")
    for key in (
        "CHECKPOINT_ENV_ONLY",
        "CHECKPOINT_LEGACY_ONLY",
        "CHECKPOINT_LOCAL_ONLY",
    ):
        monkeypatch.delenv(key, raising=False)

    _load_operator_environment([tmp_path])

    assert os.environ["CHECKPOINT_PROCESS_WINS"] == "process"
    assert os.environ["CHECKPOINT_PRECEDENCE"] == "process-wins"
    assert os.environ["CHECKPOINT_LOCAL_ONLY"] == "local-only"
    assert os.environ["CHECKPOINT_LEGACY_ONLY"] == "legacy-only"
    assert os.environ["CHECKPOINT_ENV_ONLY"] == "env-only"


def test_root_local_beats_legacy_when_process_is_unset(
    monkeypatch, tmp_path: Path
) -> None:
    scripts = tmp_path / "scripts"
    scripts.mkdir()
    (tmp_path / ".env.local").write_text(
        "CHECKPOINT_FILE_PRECEDENCE=root-local\n", encoding="utf-8"
    )
    (scripts / ".env.local").write_text(
        "CHECKPOINT_FILE_PRECEDENCE=legacy\n", encoding="utf-8"
    )
    monkeypatch.delenv("CHECKPOINT_FILE_PRECEDENCE", raising=False)

    _load_operator_environment([tmp_path])

    assert os.environ["CHECKPOINT_FILE_PRECEDENCE"] == "root-local"


def test_common_bright_data_alias_is_normalized_without_overriding_canonical(
    monkeypatch, tmp_path: Path
) -> None:
    monkeypatch.delenv("BRIGHT_DATA_API_KEY", raising=False)
    monkeypatch.delenv("BRIGHTDATA_API_KEY", raising=False)
    (tmp_path / ".env.local").write_text(
        "BRIGHTDATA_API_KEY=alias-key\n", encoding="utf-8"
    )

    _load_operator_environment([tmp_path])

    assert os.environ["BRIGHT_DATA_API_KEY"] == "alias-key"

    monkeypatch.setenv("BRIGHT_DATA_API_KEY", "canonical-key")
    _load_operator_environment([tmp_path])
    assert os.environ["BRIGHT_DATA_API_KEY"] == "canonical-key"


def test_higher_precedence_legacy_alias_beats_lower_precedence_canonical_name(
    monkeypatch, tmp_path: Path
) -> None:
    monkeypatch.delenv("BRIGHT_DATA_API_KEY", raising=False)
    monkeypatch.delenv("BRIGHTDATA_API_KEY", raising=False)
    scripts = tmp_path / "scripts"
    scripts.mkdir()
    (scripts / ".env.local").write_text(
        "BRIGHTDATA_API_KEY=legacy-local-key\n", encoding="utf-8"
    )
    (tmp_path / ".env").write_text(
        "BRIGHT_DATA_API_KEY=lower-priority-key\n", encoding="utf-8"
    )

    _load_operator_environment([tmp_path])

    assert os.environ["BRIGHT_DATA_API_KEY"] == "legacy-local-key"
