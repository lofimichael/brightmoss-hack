import json
from pathlib import Path

from fastapi.testclient import TestClient

from checkpoint_agent.enrichment import (
    BrightDataRemoteMCPAdapter,
    UnavailablePublicEnricher,
)
from checkpoint_agent.freshness import UnavailableSavedURLFetcher
from checkpoint_agent.planner import DeterministicPlanner
from checkpoint_agent.retrieval import MossSessionSearchIndex, UnavailableSearchIndex
from checkpoint_agent.schemas import ProviderConfigurationRequest
from checkpoint_agent.server import create_app


def configured_app(database: Path):
    return create_app(
        database_path=str(database),
        index=UnavailableSearchIndex(),
        planner=DeterministicPlanner(),
        fetcher=UnavailableSavedURLFetcher(),
        enricher=UnavailablePublicEnricher(),
        bearer_token="loopback-token",
    )


def test_provider_configuration_is_authenticated_and_never_echoes_secrets(
    tmp_path: Path,
) -> None:
    secret = "bright-secret-value-that-must-not-echo"
    app = configured_app(tmp_path / "checkpoint.sqlite")
    with TestClient(app) as client:
        assert (
            client.post(
                "/providers/configure", json={"bright_data_api_key": secret}
            ).status_code
            == 401
        )
        response = client.post(
            "/providers/configure",
            headers={"Authorization": "Bearer loopback-token"},
            json={"bright_data_api_key": secret},
        )
        assert response.status_code == 200
        assert response.json()["bright_data"] == "ready"
        assert response.json()["bright_data_mode"] == "remote_mcp"
        assert secret not in response.text
        assert secret not in repr(app.state.runtime)
        assert secret not in repr(app.state.runtime.provider_memory)
        assert secret not in repr(BrightDataRemoteMCPAdapter(secret))

        sandbox_only = client.post(
            "/providers/configure",
            headers={"Authorization": "Bearer loopback-token"},
            json={"livekit_sandbox_id": "sandbox-id"},
        ).json()
        assert sandbox_only["voice"] == "not_configured"

        voice = client.post(
            "/providers/configure",
            headers={"Authorization": "Bearer loopback-token"},
            json={
                "livekit_url": "wss://example.livekit.cloud",
                "livekit_api_key": "livekit-key",
                "livekit_api_secret": "livekit-secret",
            },
        ).json()
        assert voice["voice"] == "restart_required"

    configuration = ProviderConfigurationRequest(bright_data_api_key=secret)
    assert secret not in repr(configuration)


def test_explicit_null_removes_provider_secrets_and_restores_local_fallbacks(
    tmp_path: Path, monkeypatch
) -> None:
    sentinel = UnavailableSearchIndex("configured-moss")
    sentinel.available = True

    async def fake_from_credentials(cls, supplied_id: str, supplied_key: str):
        del cls, supplied_id, supplied_key
        return sentinel

    monkeypatch.setattr(
        MossSessionSearchIndex,
        "from_credentials",
        classmethod(fake_from_credentials),
    )

    app = configured_app(tmp_path / "checkpoint.sqlite")
    headers = {"Authorization": "Bearer loopback-token"}
    with TestClient(app) as client:
        configured = client.post(
            "/providers/configure",
            headers=headers,
            json={
                "bright_data_api_key": "bright-secret",
                "moss_project_id": "moss-project",
                "moss_project_key": "moss-secret",
                "openai_api_key": "openai-secret",
                "livekit_url": "wss://example.livekit.cloud",
                "livekit_api_key": "livekit-key",
                "livekit_api_secret": "livekit-secret",
            },
        )
        assert configured.status_code == 200
        assert configured.json() == {
            "bright_data": "ready",
            "bright_data_mode": "remote_mcp",
            "moss": "ready",
            "planner": "openai",
            "voice": "restart_required",
            "local_retrieval": True,
        }

        removed = client.post(
            "/providers/configure",
            headers=headers,
            json={
                "bright_data_api_key": None,
                "moss_project_id": None,
                "moss_project_key": None,
                "openai_api_key": None,
                "livekit_url": None,
                "livekit_api_key": None,
                "livekit_api_secret": None,
            },
        )
        assert removed.status_code == 200
        assert removed.json() == {
            "bright_data": "not_configured",
            "bright_data_mode": "none",
            "moss": "not_configured",
            "planner": "local",
            "voice": "not_configured",
            "local_retrieval": True,
        }

    memory = app.state.runtime.provider_memory
    assert memory.bright_data_api_key is None
    assert memory.moss_project_id is None
    assert memory.moss_project_key is None
    assert memory.openai_api_key is None
    assert memory.livekit_url is None
    assert memory.livekit_api_key is None
    assert memory.livekit_api_secret is None
    assert not app.state.runtime.orchestrator.index.available
    assert app.state.runtime.orchestrator.planner.name == "deterministic"


def test_invalid_provider_value_is_sanitized_in_422(tmp_path: Path) -> None:
    secret = "rejected-secret-input"
    with TestClient(configured_app(tmp_path / "checkpoint.sqlite")) as client:
        response = client.post(
            "/providers/configure",
            headers={"Authorization": "Bearer loopback-token"},
            json={"bright_data_api_key": {"secret": secret}},
        )
        assert response.status_code == 422
        assert response.json() == {"detail": "invalid provider configuration"}
        assert secret not in response.text

        raw_moss_key = "raw-moss-key-is-not-a-project-bundle"
        moss_response = client.post(
            "/providers/configure",
            headers={"Authorization": "Bearer loopback-token"},
            json={"moss_credential": raw_moss_key},
        )
        assert moss_response.status_code == 422
        assert raw_moss_key not in moss_response.text


def test_provider_configuration_body_is_bounded(tmp_path: Path) -> None:
    secret = "x" * 24_001
    with TestClient(configured_app(tmp_path / "checkpoint.sqlite")) as client:
        response = client.post(
            "/providers/configure",
            headers={"Authorization": "Bearer loopback-token"},
            content='{"bright_data_api_key":"' + secret + '"}',
        )
        assert response.status_code == 413
        assert secret not in response.text


def test_single_moss_json_bundle_configures_both_required_values(
    tmp_path: Path, monkeypatch
) -> None:
    project_id = "bundle-project"
    project_key = "bundle-key-that-must-not-echo"
    calls: list[tuple[str, str]] = []
    sentinel = UnavailableSearchIndex("ready-test-index")
    sentinel.available = True

    async def fake_from_credentials(cls, supplied_id: str, supplied_key: str):
        del cls
        calls.append((supplied_id, supplied_key))
        return sentinel

    monkeypatch.setattr(
        MossSessionSearchIndex,
        "from_credentials",
        classmethod(fake_from_credentials),
    )
    bundle = json.dumps({"project_id": project_id, "project_key": project_key})
    with TestClient(configured_app(tmp_path / "checkpoint.sqlite")) as client:
        response = client.post(
            "/providers/configure",
            headers={"Authorization": "Bearer loopback-token"},
            json={"moss_credential": bundle},
        )
        assert response.status_code == 200
        assert response.json()["moss"] == "ready"
        assert project_id not in response.text
        assert project_key not in response.text
    assert calls == [(project_id, project_key)]


async def test_moss_auto_enables_with_credentials_and_explicit_false_disables(
    monkeypatch,
) -> None:
    sentinel = UnavailableSearchIndex("sentinel")
    calls: list[tuple[str, str]] = []

    async def fake_from_credentials(cls, project_id: str, project_key: str):
        del cls
        calls.append((project_id, project_key))
        return sentinel

    monkeypatch.setattr(
        MossSessionSearchIndex,
        "from_credentials",
        classmethod(fake_from_credentials),
    )
    monkeypatch.setenv("MOSS_PROJECT_ID", "project")
    monkeypatch.setenv("MOSS_PROJECT_KEY", "key")
    monkeypatch.delenv("CHECKPOINT_ENABLE_MOSS_SESSION", raising=False)

    assert await MossSessionSearchIndex.from_environment() is sentinel
    assert calls == [("project", "key")]

    monkeypatch.setenv("CHECKPOINT_ENABLE_MOSS_SESSION", "false")
    disabled = await MossSessionSearchIndex.from_environment()
    assert not disabled.available
    assert calls == [("project", "key")]
