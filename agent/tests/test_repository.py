import stat
from pathlib import Path

from checkpoint_agent.repository import CheckpointRepository
from checkpoint_agent.schemas import Artifact, CheckpointCreate


def checkpoint() -> CheckpointCreate:
    return CheckpointCreate(
        title="BrightMoss auth",
        summary="JWT token generation is blocking the Mac agent.",
        next_step="Fix the token endpoint problem.",
        artifacts=[
            Artifact(
                kind="url",
                display_name="LiveKit docs",
                resource="https://docs.livekit.io/agents/",
                captured_text="Agents join a room using a token.",
            )
        ],
    )


def test_checkpoint_survives_restart_and_fuzzy_literal_fallback(tmp_path: Path) -> None:
    database = tmp_path / "checkpoint.sqlite"
    repository = CheckpointRepository(database)
    assert stat.S_IMODE(database.stat().st_mode) == 0o600
    saved = repository.save(checkpoint())
    repository.close()

    reopened = CheckpointRepository(database)
    hits = reopened.search("resume the thing where token auth blocked me")

    assert hits[0][0].id == saved.id
    assert hits[0][0].artifacts[0].resource == "https://docs.livekit.io/agents/"
    reopened.close()


def test_save_source_version_and_delete_cascades(tmp_path: Path) -> None:
    repository = CheckpointRepository(tmp_path / "checkpoint.sqlite")
    saved = repository.save(checkpoint())
    version = repository.save_source_version(
        checkpoint_id=saved.id,
        canonical_url="https://docs.livekit.io/agents/",
        body_hash="abc",
        normalized_text="new docs",
    )

    assert repository.latest_source_version(saved.id, version.canonical_url) == version
    assert repository.delete(saved.id)
    assert repository.get(saved.id) is None
    assert repository.latest_source_version(saved.id, version.canonical_url) is None
    repository.close()
