from datetime import datetime, timezone
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from checkpoint_agent.enrichment import (
    BrightDataRemoteMCPAdapter,
    UnavailablePublicEnricher,
    evaluate_public_candidate,
)
from checkpoint_agent.freshness import FreshnessError, UnavailableSavedURLFetcher
from checkpoint_agent.planner import DeterministicPlanner
from checkpoint_agent.retrieval import UnavailableSearchIndex
from checkpoint_agent.schemas import (
    PublicEnrichmentCandidate,
    PublicSource,
)
from checkpoint_agent.server import create_app


class RecordingIndex(UnavailableSearchIndex):
    def __init__(self) -> None:
        super().__init__()
        self.documents: dict[str, dict] = {}

    async def upsert_graph_documents(self, documents: list[dict]) -> None:
        self.documents.update({document["id"]: document for document in documents})


class RecordingEnricher:
    name = "fake-public-web"
    available = True

    def __init__(self) -> None:
        self.queries: list[tuple[str, int]] = []

    async def search(self, query: str, limit: int) -> list[PublicSource]:
        self.queries.append((query, limit))
        return [
            PublicSource(
                title=f"Official result {number}",
                url=f"https://docs.example.com/result-{number}",
                snippet="Public documentation snippet.",
            )
            for number in range(3)
        ]


def app_for(
    database: Path,
    *,
    index: RecordingIndex | None = None,
    enricher: RecordingEnricher | UnavailablePublicEnricher | None = None,
):
    return create_app(
        database_path=str(database),
        index=index or RecordingIndex(),
        planner=DeterministicPlanner(),
        fetcher=UnavailableSavedURLFetcher(),
        enricher=enricher or UnavailablePublicEnricher(),
        bearer_token=None,
    )


def _save_episode(client: TestClient) -> str:
    response = client.post(
        "/checkpoints",
        json={
            "title": "LiveKit token debugging",
            "summary": "Investigating an invalid JWT issuer.",
        },
    )
    assert response.status_code == 201
    return response.json()["id"]


def test_local_observation_builds_sqlite_graph_and_compact_index(
    tmp_path: Path,
) -> None:
    index = RecordingIndex()
    with TestClient(app_for(tmp_path / "graph.sqlite", index=index)) as client:
        checkpoint_id = _save_episode(client)
        response = client.post(
            "/observations",
            json={
                "checkpoint_id": checkpoint_id,
                "captured_at": datetime.now(timezone.utc).isoformat(),
                "app_bundle_id": "com.apple.dt.Xcode",
                "window_title": "TokenService.swift",
                "document_resource": "/private/project/TokenService.swift",
                "extracted_text": "invalid JWT issuer",
                "extraction_method": "accessibility",
                "subjects": [
                    {
                        "canonical_name": "LiveKit access-token validation",
                        "kind": "technology",
                        "confidence": 0.91,
                    }
                ],
                "likely_intent": {
                    "summary": "Debug LiveKit token validation",
                    "confidence": 0.86,
                },
            },
        )

        assert response.status_code == 201
        assert response.json()["content_hash"]
        graph = client.get(f"/graph/checkpoints/{checkpoint_id}").json()
        assert {node["kind"] for node in graph["nodes"]} >= {
            "episode",
            "artifact",
            "entity",
            "intent",
        }
        assert {edge["kind"] for edge in graph["edges"]} >= {
            "USED",
            "ABOUT",
            "INFERRED_INTENT",
        }
        assert graph["evidence"][0]["excerpt"] == "invalid JWT issuer"
        assert any(
            document["metadata"]["kind"] == "entity"
            and document["metadata"]["checkpoint_id"] == checkpoint_id
            for document in index.documents.values()
        )
        local_fallback = client.post(
            "/turn", json={"text": "where was TokenService.swift?"}
        ).json()
        assert local_fallback["checkpoint"]["id"] == checkpoint_id
        assert local_fallback["provider_disclosure"] == ["Local memory"]

        erased = client.post("/memory/erase-recent", json={"minutes": 15}).json()
        assert erased["observations"] == 1
        assert erased["evidence"] == 1
        remaining = client.get(f"/graph/checkpoints/{checkpoint_id}").json()
        assert [node["kind"] for node in remaining["nodes"]] == ["episode"]
        assert client.get(f"/checkpoints/{checkpoint_id}").status_code == 200


def test_passive_observation_creates_a_retrievable_daily_ambient_episode(
    tmp_path: Path,
) -> None:
    index = RecordingIndex()
    captured_at = datetime(2026, 7, 18, 20, 30, tzinfo=timezone.utc)
    with TestClient(app_for(tmp_path / "ambient.sqlite", index=index)) as client:
        response = client.post(
            "/observations",
            json={
                "captured_at": captured_at.isoformat(),
                "application_name": "Safari",
                "app_bundle_id": "com.apple.Safari",
                "window_title": "LiveKit documentation",
                "document_resource": "https://docs.livekit.io/agents/",
                "subjects": [
                    {
                        "canonical_name": "docs.livekit.io",
                        "kind": "public_documentation",
                    }
                ],
                "likely_intent": {"summary": "Reading LiveKit documentation"},
            },
        )

        assert response.status_code == 201
        checkpoint_id = response.json()["checkpoint_id"]
        assert checkpoint_id == "ambient-2026-07-18"
        checkpoint = client.get(f"/checkpoints/{checkpoint_id}").json()
        assert checkpoint["title"] == "Workspace memory · Jul 18"
        assert checkpoint["summary"] == "Reading LiveKit documentation"
        assert {artifact["kind"] for artifact in checkpoint["artifacts"]} == {
            "app",
            "url",
        }
        found = client.post(
            "/turn", json={"text": "where was I reading LiveKit documentation?"}
        ).json()
        assert found["checkpoint"]["id"] == checkpoint_id
        assert found["message"] == "Most recently, reading LiveKit documentation."
        assert found["provider_disclosure"] == ["Local memory"]
        assert any(
            document["metadata"]["checkpoint_id"] == checkpoint_id
            for document in index.documents.values()
        )


def test_recent_erase_removes_the_derived_ambient_episode_too(tmp_path: Path) -> None:
    with TestClient(app_for(tmp_path / "erase-ambient.sqlite")) as client:
        saved = client.post(
            "/observations",
            json={
                "captured_at": datetime.now(timezone.utc).isoformat(),
                "application_name": "Safari",
                "app_bundle_id": "com.apple.Safari",
                "window_title": "Private launch plan",
                "document_resource": "/private/project/launch.md",
                "likely_intent": {"summary": "Review the private launch plan"},
            },
        ).json()
        checkpoint_id = saved["checkpoint_id"]

        erased = client.post("/memory/erase-recent", json={"minutes": 15}).json()

        assert erased["observations"] == 1
        assert client.get(f"/checkpoints/{checkpoint_id}").status_code == 404
        recalled = client.post(
            "/turn", json={"text": "where is the private launch plan?"}
        ).json()
        assert recalled.get("checkpoint") is None


@pytest.mark.parametrize(
    ("query", "reason"),
    [
        ("LiveKit from /Users/alice/Secret.swift", "contains_local_path"),
        ("LiveKit owner alice@example.com", "contains_email"),
        ("LiveKit at 10.0.0.4", "contains_ip_address"),
        ("LiveKit password=hunter2", "contains_credentials"),
        ("LiveKit docs on auth.internal", "contains_private_host"),
        ("secret unrelated research", "query_subject_mismatch"),
    ],
)
def test_public_policy_rejects_private_expansion(query: str, reason: str) -> None:
    decision = evaluate_public_candidate(
        PublicEnrichmentCandidate(
            canonical_name="LiveKit",
            kind="technology",
            query=query,
        )
    )
    assert not decision.allowed
    assert decision.reason == reason
    assert decision.query is None
    assert decision.subject is None


async def test_network_adapter_rechecks_query_at_the_last_boundary() -> None:
    adapter = BrightDataRemoteMCPAdapter("unused-test-key")
    with pytest.raises(FreshnessError):
        await adapter.search("LiveKit owner alice@example.com")


def test_enrichment_is_policy_gated_bounded_and_cached(tmp_path: Path) -> None:
    enricher = RecordingEnricher()
    database = tmp_path / "graph.sqlite"
    with TestClient(app_for(database, enricher=enricher)) as client:
        checkpoint_id = _save_episode(client)
        rejected_query = "LiveKit owner alice@example.com"
        rejected = client.post(
            "/enrichments",
            json={
                "checkpoint_id": checkpoint_id,
                "candidate": {
                    "canonical_name": "LiveKit",
                    "kind": "technology",
                    "query": rejected_query,
                },
            },
        )
        assert rejected.status_code == 200
        assert rejected.json()["status"] == "rejected"
        assert rejected_query not in rejected.text
        assert enricher.queries == []

        consented_private_query = client.post(
            "/enrichments",
            json={
                "checkpoint_id": checkpoint_id,
                "allow_public_enrichment": True,
                "candidate": {
                    "canonical_name": "LiveKit",
                    "kind": "technology",
                    "query": rejected_query,
                },
            },
        ).json()
        assert consented_private_query["status"] == "rejected"
        synthetic = "SYNTHETIC_PRIVATE_CODENAME"
        uncorroborated = client.post(
            "/enrichments",
            json={
                "checkpoint_id": checkpoint_id,
                "allow_public_enrichment": True,
                "candidate": {
                    "canonical_name": synthetic,
                    "kind": "technology",
                    "query": f"{synthetic} official documentation latest",
                },
            },
        ).json()
        assert uncorroborated["status"] == "rejected"
        assert enricher.queries == []

        payload = {
            "checkpoint_id": checkpoint_id,
            "allow_public_enrichment": True,
            "candidate": {
                "canonical_name": "LiveKit",
                "kind": "technology",
                "query": "LiveKit official documentation latest",
            },
        }
        first = client.post("/enrichments", json=payload).json()
        second = client.post("/enrichments", json=payload).json()

        assert first["status"] == "complete"
        assert second["status"] == "cached"
        assert len(first["sources"]) == 2
        assert enricher.queries == [(payload["candidate"]["query"], 2)]
        graph = client.get(f"/graph/checkpoints/{checkpoint_id}").json()
        assert sum(node["kind"] == "web_source" for node in graph["nodes"]) == 2
        recalled = client.post("/turn", json={"text": "find LiveKit"}).json()
        assert len(recalled["sources"]) == 2
        assert {source["url"] for source in recalled["sources"]} == {
            "https://docs.example.com/result-0",
            "https://docs.example.com/result-1",
        }
        assert recalled["provider_disclosure"] == [
            "Local memory",
            "Bright Data · public context",
        ]
    assert rejected_query.encode() not in database.read_bytes()
    assert b"SYNTHETIC_PRIVATE_CODENAME" not in database.read_bytes()
