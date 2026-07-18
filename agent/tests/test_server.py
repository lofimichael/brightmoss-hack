import asyncio
import json
import stat
import threading
import time
from pathlib import Path

from fastapi.testclient import TestClient

from checkpoint_agent.freshness import UnavailableSavedURLFetcher
from checkpoint_agent.planner import DeterministicPlanner
from checkpoint_agent.retrieval import MossSessionSearchIndex, UnavailableSearchIndex
from checkpoint_agent.server import create_app


CHECKPOINT = {
    "title": "BrightMoss auth",
    "summary": "JWT token generation is blocking the Mac agent.",
    "next_step": "Fix the token endpoint problem.",
    "artifacts": [
        {
            "kind": "app",
            "display_name": "Xcode",
            "bundle_id": "com.apple.dt.Xcode",
        },
        {
            "kind": "file",
            "display_name": "Agent.swift",
            "resource": "/tmp/Agent.swift",
        },
        {
            "kind": "url",
            "display_name": "LiveKit docs",
            "resource": "https://docs.livekit.io/agents/",
            "captured_text": "Agents join rooms using tokens.",
        },
    ],
}


def app_for(database: Path, token: str | None = None):
    return create_app(
        database_path=str(database),
        index=UnavailableSearchIndex(),
        planner=DeterministicPlanner(),
        fetcher=UnavailableSavedURLFetcher(),
        bearer_token=token,
    )


def test_typed_save_search_restore_and_separate_approval(tmp_path: Path) -> None:
    with TestClient(app_for(tmp_path / "checkpoint.sqlite")) as client:
        saved_response = client.post("/checkpoints", json=CHECKPOINT)
        assert saved_response.status_code == 201
        saved = saved_response.json()

        recent = client.get("/checkpoints").json()
        assert [item["id"] for item in recent] == [saved["id"]]

        found = client.post(
            "/turn", json={"text": "find the token endpoint", "modality": "typed"}
        ).json()
        assert found["kind"] == "result_card"
        assert found["checkpoint"]["id"] == saved["id"]
        assert found["proposal_id"] is None

        restore = client.post(
            "/turn",
            json={
                "text": "resume the thing where token auth blocked me",
                "modality": "voice",
            },
        ).json()
        assert restore["kind"] == "confirmation_card"
        assert restore["proposal_id"]
        assert [action["kind"] for action in restore["proposed_actions"]] == [
            "activateApp",
            "openFile",
            "openURL",
        ]

        approved = client.post(
            f"/proposals/{restore['proposal_id']}/decision",
            json={"decision": "approve"},
        ).json()
        assert approved["kind"] == "result_card"
        assert approved["status"] == "approved"
        assert approved["proposal_id"] == restore["proposal_id"]
        assert approved["proposed_actions"] == restore["proposed_actions"]
        assert (
            client.post(
                f"/proposals/{restore['proposal_id']}/decision",
                json={"decision": "approve"},
            ).status_code
            == 409
        )


def test_cancel_returns_no_stale_actions(tmp_path: Path) -> None:
    with TestClient(app_for(tmp_path / "checkpoint.sqlite")) as client:
        client.post("/checkpoints", json=CHECKPOINT)
        proposal = client.post(
            "/turn", json={"text": "reopen BrightMoss auth", "modality": "typed"}
        ).json()
        cancelled = client.post(
            f"/proposals/{proposal['proposal_id']}/decision",
            json={"decision": "cancel"},
        ).json()
        assert cancelled["kind"] == "result_card"
        assert cancelled["status"] == "cancelled"
        assert cancelled["proposal_id"] == proposal["proposal_id"]
        assert cancelled["proposed_actions"] == []


def test_live_web_absence_falls_back_to_saved_source(tmp_path: Path) -> None:
    with TestClient(app_for(tmp_path / "checkpoint.sqlite")) as client:
        saved = client.post("/checkpoints", json=CHECKPOINT).json()
        response = client.post(
            "/turn",
            json={
                "text": "refresh the saved page",
                "modality": "typed",
                "checkpoint_id": saved["id"],
                "url": "https://docs.livekit.io/agents/",
            },
        ).json()
        assert response["kind"] == "result_card"
        assert response["provider_disclosure"] == ["Local memory"]
        assert response["sources"][0]["baseline"] == "saved excerpt"


def test_bearer_token_is_enforced_when_configured(tmp_path: Path) -> None:
    with TestClient(app_for(tmp_path / "checkpoint.sqlite", token="secret")) as client:
        assert client.get("/health").status_code == 401
        assert (
            client.get(
                "/health", headers={"Authorization": "Bearer secret"}
            ).status_code
            == 200
        )


def test_default_runtime_publishes_private_ephemeral_connection(
    tmp_path: Path, monkeypatch
) -> None:
    monkeypatch.setenv("CHECKPOINT_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("CHECKPOINT_PORT", "43117")
    monkeypatch.delenv("CHECKPOINT_CONTROL_TOKEN", raising=False)
    monkeypatch.delenv("CHECKPOINT_BEARER_TOKEN", raising=False)
    app = create_app(
        index=UnavailableSearchIndex(),
        planner=DeterministicPlanner(),
        fetcher=UnavailableSavedURLFetcher(),
    )
    connection_path = tmp_path / "agent-connection.json"

    with TestClient(app) as client:
        connection = json.loads(connection_path.read_text())
        assert connection["base_url"] == "http://127.0.0.1:43117"
        assert connection["port"] == 43117
        assert connection["token"]
        assert stat.S_IMODE(connection_path.stat().st_mode) == 0o600
        assert client.get("/health").status_code == 401
        assert (
            client.get(
                "/health",
                headers={"Authorization": f"Bearer {connection['token']}"},
            ).status_code
            == 200
        )

    assert not connection_path.exists()


def test_default_runtime_serves_local_memory_while_moss_warms(
    tmp_path: Path, monkeypatch
) -> None:
    moss_started = threading.Event()

    async def delayed_moss_initialization(_cls):
        moss_started.set()
        await asyncio.sleep(2.0)
        return UnavailableSearchIndex("test warm-up complete")

    monkeypatch.setattr(
        MossSessionSearchIndex,
        "from_environment",
        classmethod(delayed_moss_initialization),
    )
    app = create_app(
        database_path=str(tmp_path / "checkpoint.sqlite"),
        planner=DeterministicPlanner(),
        fetcher=UnavailableSavedURLFetcher(),
        bearer_token=None,
    )

    started_at = time.monotonic()
    with TestClient(app) as client:
        startup_duration = time.monotonic() - started_at
        assert moss_started.wait(timeout=0.5)
        assert client.get("/health").json()["search"] == "sqlite-substring"

        saved = client.post("/checkpoints", json=CHECKPOINT).json()
        found = client.post(
            "/turn", json={"text": "find the token endpoint", "modality": "typed"}
        ).json()
        assert found["checkpoint"]["id"] == saved["id"]

    # A remote provider can be slow or unavailable without delaying local
    # readiness. This deliberately leaves generous headroom for loaded CI.
    assert startup_duration < 1.0
