from __future__ import annotations

from datetime import datetime, timedelta, timezone
from pathlib import Path
import sqlite3

from fastapi.testclient import TestClient
import pytest

from checkpoint_agent.freshness import UnavailableSavedURLFetcher
from checkpoint_agent.planner import DeterministicPlanner
from checkpoint_agent.retrieval import UnavailableSearchIndex
from checkpoint_agent.schemas import PublicSource
from checkpoint_agent.server import create_app


class RecordingEnricher:
    name = "recording-bright-data"
    available = True

    def __init__(self) -> None:
        self.queries: list[str] = []

    async def search(self, query: str, limit: int) -> list[PublicSource]:
        self.queries.append(query)
        return [
            PublicSource(
                title=f"Result {number}",
                url=f"https://public.example/result-{len(self.queries)}-{number}",
                snippet=f"Public result for {query}",
            )
            for number in range(limit)
        ]


class RecordingFetcher:
    name = "recording-fetcher"
    available = True

    def __init__(self) -> None:
        self.urls: list[str] = []

    async def fetch(self, url: str) -> str:
        self.urls.append(url)
        return "<main>Current public documentation.</main>"


class FailingEnricher:
    name = "failing-bright-data"
    available = True

    def __init__(self) -> None:
        self.calls = 0

    async def search(self, query: str, limit: int) -> list[PublicSource]:
        del query, limit
        self.calls += 1
        raise RuntimeError("synthetic provider failure")


def app_for(
    database: Path,
    *,
    enricher: RecordingEnricher | None = None,
    fetcher: RecordingFetcher | None = None,
):
    return create_app(
        database_path=str(database),
        index=UnavailableSearchIndex(),
        planner=DeterministicPlanner(),
        fetcher=fetcher or UnavailableSavedURLFetcher(),
        enricher=enricher,
        bearer_token=None,
    )


def observation_payload(
    *,
    captured_at: datetime,
    subject: str = "LiveKit",
    kind: str = "technology",
    confidence: float = 0.95,
    allow_public_enrichment: bool = True,
) -> dict:
    return {
        "captured_at": captured_at.isoformat(),
        "application_name": "Xcode",
        "app_bundle_id": "com.apple.dt.Xcode",
        "window_title": "SecretProject.swift — alice@example.com",
        "document_resource": "/Users/alice/private/SecretProject.swift",
        "extracted_text": "private token failure in Project Cormorant",
        "extraction_method": "accessibility",
        "subjects": [
            {
                "canonical_name": subject,
                "kind": kind,
                "keywords": ["access tokens", "Project Cormorant"],
                "confidence": confidence,
            }
        ],
        "likely_intent": {
            "summary": "Fix Project Cormorant for alice@example.com",
            "confidence": 0.88,
        },
        "allow_public_enrichment": allow_public_enrichment,
    }


def test_memory_timeline_subjects_stats_and_safe_automatic_expansion(
    tmp_path: Path,
) -> None:
    enricher = RecordingEnricher()
    now = datetime(2026, 7, 18, 20, 0, tzinfo=timezone.utc)
    with TestClient(app_for(tmp_path / "memory.sqlite", enricher=enricher)) as client:
        saved = client.post("/observations", json=observation_payload(captured_at=now))
        assert saved.status_code == 201
        assert saved.json()["enrichment"]["status"] == "complete"
        assert saved.json()["enrichment"]["outbound_query"] == (
            "LiveKit official documentation latest"
        )
        assert len(saved.json()["enrichment"]["sources"]) == 2
        assert enricher.queries == ["LiveKit official documentation latest"]
        outbound = enricher.queries[0]
        for private_value in (
            "SecretProject",
            "alice",
            "/Users",
            "Cormorant",
            "token failure",
        ):
            assert private_value not in outbound

        timeline = client.get("/memory/items?limit=20").json()
        assert timeline["total"] == 1
        item = timeline["items"][0]
        assert item["id"] == saved.json()["id"]
        assert item["document_label"] == "SecretProject.swift"
        assert "document_resource" not in item
        assert item["subjects"][0]["keywords"] == [
            "access tokens",
            "Project Cormorant",
        ]
        assert item["likely_intent"]["summary"].startswith("Fix Project")
        assert item["enrichment_status"] == "complete"
        assert item["outbound_query"] == "LiveKit official documentation latest"
        assert len(item["public_sources"]) == 2
        assert item["provenance"] == ["local", "bright_data"]
        graph = client.get(f"/graph/checkpoints/{saved.json()['checkpoint_id']}").json()
        livekit_entities = [
            node
            for node in graph["nodes"]
            if node["kind"] == "entity" and node["label"] == "LiveKit"
        ]
        assert len(livekit_entities) == 1
        assert livekit_entities[0]["sensitivity"] == "private"
        assert sum(edge["kind"] == "SUPPORTED_BY" for edge in graph["edges"]) == 2
        keyword_recall = client.post(
            "/turn", json={"text": "where did I see access tokens?"}
        ).json()
        assert keyword_recall["checkpoint"]["id"] == saved.json()["checkpoint_id"]

        subjects = client.get("/memory/subjects").json()
        assert subjects["total"] == 1
        assert subjects["subjects"][0] == {
            "canonical_name": "LiveKit",
            "kind": "technology",
            "keywords": ["access tokens", "Project Cormorant"],
            "count": 1,
            "first_seen": now.isoformat().replace("+00:00", "Z"),
            "last_seen": now.isoformat().replace("+00:00", "Z"),
            "apps": ["Xcode"],
            "public_sources": item["public_sources"],
        }
        assert client.get("/memory/stats").json() == {
            "total_memories": 1,
            "total_subjects": 1,
            "enriched_memories": 1,
            "public_sources": 2,
            "categories": {"technology": 1},
        }


def test_cache_is_network_idempotent_and_can_link_a_second_observation(
    tmp_path: Path,
) -> None:
    enricher = RecordingEnricher()
    now = datetime(2026, 7, 18, 20, 0, tzinfo=timezone.utc)
    database = tmp_path / "cache.sqlite"
    with TestClient(app_for(database, enricher=enricher)) as client:
        first = client.post(
            "/observations", json=observation_payload(captured_at=now)
        ).json()
        second = client.post(
            "/observations",
            json=observation_payload(captured_at=now + timedelta(minutes=1)),
        ).json()
        assert len(enricher.queries) == 1
        assert second["enrichment"]["status"] == "cached"

        cached = client.post(
            "/enrichments",
            json={
                "checkpoint_id": second["checkpoint_id"],
                "observation_id": second["id"],
                "allow_public_enrichment": True,
                "candidate": {
                    "canonical_name": "LiveKit",
                    "kind": "technology",
                    "query": "LiveKit official documentation latest",
                },
            },
        ).json()
        assert cached["status"] == "cached"
        assert len(enricher.queries) == 1
        items = client.get("/memory/items").json()["items"]
        linked = next(item for item in items if item["id"] == second["id"])
        assert linked["enrichment_status"] == "cached"
        assert len(linked["public_sources"]) == 2
        assert first["id"] != second["id"]
        aggregate = client.get("/memory/subjects").json()["subjects"][0]
        assert aggregate["count"] == 2
        assert aggregate["first_seen"].startswith("2026-07-18T20:00")
        assert aggregate["last_seen"].startswith("2026-07-18T20:01")
    with sqlite3.connect(database) as connection:
        attempted = connection.execute(
            "SELECT COUNT(*) FROM enrichment_job WHERE network_attempted = 1"
        ).fetchone()[0]
    assert attempted == 1


def test_private_or_low_confidence_subjects_accrue_without_network(
    tmp_path: Path,
) -> None:
    enricher = RecordingEnricher()
    now = datetime.now(timezone.utc)
    with TestClient(app_for(tmp_path / "private.sqlite", enricher=enricher)) as client:
        private = observation_payload(
            captured_at=now, subject="Project Cormorant", kind="project"
        )
        low_confidence = observation_payload(
            captured_at=now + timedelta(seconds=1),
            subject="LiveKit",
            confidence=0.4,
        )
        client.post("/observations", json=private)
        client.post("/observations", json=low_confidence)

        assert enricher.queries == []
        subjects = client.get("/memory/subjects").json()["subjects"]
        assert {(item["canonical_name"], item["kind"]) for item in subjects} == {
            ("Project Cormorant", "project"),
            ("LiveKit", "technology"),
        }


def test_observation_consent_false_stores_safe_subject_without_enrichment(
    tmp_path: Path,
) -> None:
    enricher = RecordingEnricher()
    payload = observation_payload(
        captured_at=datetime.now(timezone.utc),
        allow_public_enrichment=False,
    )
    with TestClient(
        app_for(tmp_path / "no-consent.sqlite", enricher=enricher)
    ) as client:
        response = client.post("/observations", json=payload)

        assert response.status_code == 201
        assert response.json()["enrichment"] is None
        assert enricher.queries == []
        item = client.get("/memory/items").json()["items"][0]
        assert item["enrichment_status"] is None
        assert item["outbound_query"] is None
        assert item["public_sources"] == []


def test_automatic_enrichment_distrusts_private_task_phrase_classified_as_technology(
    tmp_path: Path,
) -> None:
    enricher = RecordingEnricher()
    now = datetime.now(timezone.utc)
    unsafe = observation_payload(
        captured_at=now,
        subject="LiveKit token auth — secret-project",
        kind="technology",
        confidence=0.9,
    )
    unsafe["window_title"] = "LiveKit token auth — secret-project"
    with TestClient(
        app_for(tmp_path / "task-gate.sqlite", enricher=enricher)
    ) as client:
        rejected = client.post("/observations", json=unsafe)
        assert rejected.status_code == 201
        assert rejected.json()["enrichment"] is None
        assert enricher.queries == []
        assert (
            client.get("/memory/subjects").json()["subjects"][0]["canonical_name"]
            == "LiveKit token auth — secret-project"
        )

        synthetic = client.post(
            "/observations",
            json=observation_payload(
                captured_at=now + timedelta(milliseconds=500),
                subject="SYNTHETIC_PRIVATE_CODENAME",
            ),
        )
        assert synthetic.status_code == 201
        assert synthetic.json()["enrichment"] is None
        assert enricher.queries == []

        safe = client.post(
            "/observations",
            json=observation_payload(
                captured_at=now + timedelta(seconds=1), subject="LiveKit"
            ),
        )
        assert safe.status_code == 201
        assert safe.json()["enrichment"]["status"] == "complete"
        assert enricher.queries == ["LiveKit official documentation latest"]


def test_hourly_network_budget_stops_after_six_attempts(tmp_path: Path) -> None:
    enricher = RecordingEnricher()
    now = datetime.now(timezone.utc)
    with TestClient(app_for(tmp_path / "budget.sqlite", enricher=enricher)) as client:
        records = []
        for number in range(7):
            payload = observation_payload(
                captured_at=now + timedelta(seconds=number),
                subject=f"Technology {number}",
            )
            payload["document_resource"] = f"https://technology-{number}.example/docs"
            records.append(client.post("/observations", json=payload).json())

        assert len(enricher.queries) == 6
        items = client.get("/memory/items?limit=20").json()["items"]
        limited = next(item for item in items if item["id"] == records[-1]["id"])
        assert limited["enrichment_status"] == "rate_limited"
        assert limited["outbound_query"] == (
            "Technology 6 official documentation latest"
        )
        assert limited["public_sources"] == []


def test_turn_consent_blocks_refresh_provider_even_when_configured(
    tmp_path: Path,
) -> None:
    fetcher = RecordingFetcher()
    with TestClient(app_for(tmp_path / "consent.sqlite", fetcher=fetcher)) as client:
        checkpoint = client.post(
            "/checkpoints",
            json={
                "title": "LiveKit docs",
                "summary": "Reading access token guidance.",
                "artifacts": [
                    {
                        "kind": "url",
                        "display_name": "LiveKit",
                        "resource": "https://docs.livekit.io/agents/",
                        "captured_text": "Saved guidance.",
                    }
                ],
            },
        ).json()
        denied = client.post(
            "/turn",
            json={
                "text": "refresh the saved page",
                "checkpoint_id": checkpoint["id"],
                "allow_public_enrichment": False,
            },
        ).json()
        assert fetcher.urls == []
        assert denied["provider_disclosure"] == ["Local memory"]

        allowed = client.post(
            "/turn",
            json={
                "text": "refresh the saved page",
                "checkpoint_id": checkpoint["id"],
                "allow_public_enrichment": True,
            },
        ).json()
        assert fetcher.urls == ["https://docs.livekit.io/agents/"]
        assert allowed["provider_disclosure"] == ["Bright Data · live web"]


def test_delete_memory_item_cleans_graph_aggregation_and_ambient_checkpoint(
    tmp_path: Path,
) -> None:
    enricher = RecordingEnricher()
    now = datetime.now(timezone.utc)
    with TestClient(app_for(tmp_path / "delete.sqlite", enricher=enricher)) as client:
        first = client.post(
            "/observations",
            json=observation_payload(captured_at=now, subject="LiveKit"),
        ).json()
        second = client.post(
            "/observations",
            json=observation_payload(
                captured_at=now + timedelta(seconds=1), subject="Bright Data"
            ),
        ).json()
        deleted = client.delete(f"/memory/items/{first['id']}").json()
        assert deleted == {
            "observation_id": first["id"],
            "deleted": True,
            "checkpoint_deleted": False,
        }
        assert client.get("/memory/items").json()["total"] == 1
        assert [
            subject["canonical_name"]
            for subject in client.get("/memory/subjects").json()["subjects"]
        ] == ["Bright Data"]
        graph = client.get(f"/graph/checkpoints/{second['checkpoint_id']}").json()
        assert "LiveKit" not in {node["label"] for node in graph["nodes"]}
        remaining = client.get("/memory/items").json()["items"][0]
        assert remaining["id"] == second["id"]
        assert len(remaining["public_sources"]) == 2

        final = client.delete(f"/memory/items/{second['id']}").json()
        assert final["checkpoint_deleted"] is True
        assert client.get("/memory/items").json() == {"items": [], "total": 0}
        assert client.get(f"/checkpoints/{second['checkpoint_id']}").status_code == 404
        assert client.delete(f"/memory/items/{second['id']}").status_code == 404


def test_memory_items_before_cursor_is_stable_and_total_is_global(
    tmp_path: Path,
) -> None:
    now = datetime(2026, 7, 18, 20, 0, tzinfo=timezone.utc)
    with TestClient(app_for(tmp_path / "paging.sqlite")) as client:
        for number in range(3):
            payload = observation_payload(
                captured_at=now + timedelta(minutes=number),
                allow_public_enrichment=False,
            )
            client.post("/observations", json=payload)
        page = client.get(
            "/memory/items",
            params={"limit": 1, "before": (now + timedelta(minutes=2)).isoformat()},
        ).json()
        assert page["total"] == 3
        assert len(page["items"]) == 1
        assert page["items"][0]["captured_at"].startswith("2026-07-18T20:01")


def test_memory_items_compound_cursor_keeps_tied_timestamps(tmp_path: Path) -> None:
    captured_at = datetime(2026, 7, 18, 20, 0, tzinfo=timezone.utc)
    with TestClient(app_for(tmp_path / "tied-memory.sqlite")) as client:
        ids = []
        for _ in range(3):
            ids.append(
                client.post(
                    "/observations",
                    json=observation_payload(
                        captured_at=captured_at,
                        allow_public_enrichment=False,
                    ),
                ).json()["id"]
            )
        first = client.get("/memory/items?limit=1").json()
        assert first["items"][0]["id"] == max(ids)
        cursor = first["items"][0]
        second = client.get(
            "/memory/items",
            params={
                "limit": 1,
                "before": cursor["captured_at"],
                "before_id": cursor["id"],
            },
        ).json()
        assert second["items"][0]["id"] == sorted(ids, reverse=True)[1]


@pytest.mark.parametrize("operation", ["delete", "erase"])
def test_removing_capture_refreshes_shared_artifact_text(
    tmp_path: Path, operation: str
) -> None:
    now = datetime.now(timezone.utc)
    database = tmp_path / f"artifact-{operation}.sqlite"
    application = app_for(database)
    with TestClient(application) as client:
        checkpoint = client.post(
            "/checkpoints",
            json={"title": "Artifact refresh", "summary": "Local context."},
        ).json()

        def payload(captured_at: datetime, marker: str) -> dict:
            return {
                "checkpoint_id": checkpoint["id"],
                "captured_at": captured_at.isoformat(),
                "application_name": "Xcode",
                "app_bundle_id": "com.apple.dt.Xcode",
                "window_title": f"Shared.swift {marker}",
                "document_resource": "/private/project/Shared.swift",
                "extracted_text": marker,
                "allow_public_enrichment": False,
            }

        older_marker = "ZEBRACOMET42"
        deleted_marker = "QUASARNEBULA99"
        client.post(
            "/observations", json=payload(now - timedelta(minutes=30), older_marker)
        )
        newer = client.post("/observations", json=payload(now, deleted_marker)).json()
        if operation == "delete":
            assert client.delete(f"/memory/items/{newer['id']}").status_code == 200
        else:
            assert (
                client.post("/memory/erase-recent", json={"minutes": 15}).status_code
                == 200
            )

        documents = application.state.runtime.repository.graph_documents(
            checkpoint_id=checkpoint["id"]
        )
        graph_text = "\n".join(document["text"] for document in documents)
        assert deleted_marker not in graph_text
        assert older_marker in graph_text
        forgotten = client.post("/turn", json={"text": deleted_marker}).json()
        assert forgotten.get("checkpoint") is None
        retained = client.post("/turn", json={"text": older_marker}).json()
        assert retained["checkpoint"]["id"] == checkpoint["id"]


def test_failed_cache_clones_do_not_spend_budget_and_retry_after_backoff(
    tmp_path: Path,
) -> None:
    database = tmp_path / "failure-backoff.sqlite"
    enricher = FailingEnricher()
    now = datetime.now(timezone.utc)
    with TestClient(app_for(database, enricher=enricher)) as client:
        first = client.post(
            "/observations", json=observation_payload(captured_at=now)
        ).json()
        second = client.post(
            "/observations",
            json=observation_payload(captured_at=now + timedelta(seconds=1)),
        ).json()
        assert first["enrichment"]["status"] == "failed"
        assert second["enrichment"]["status"] == "failed"
        assert enricher.calls == 1
        with sqlite3.connect(database) as connection:
            assert (
                connection.execute(
                    "SELECT COUNT(*) FROM enrichment_job WHERE network_attempted = 1"
                ).fetchone()[0]
                == 1
            )
            connection.execute(
                "UPDATE enrichment_job SET expires_at = ?",
                ((now - timedelta(minutes=1)).isoformat(),),
            )
        third = client.post(
            "/observations",
            json=observation_payload(captured_at=now + timedelta(seconds=2)),
        ).json()
        assert third["enrichment"]["status"] == "failed"
        assert enricher.calls == 2


def test_deleting_last_observation_does_not_delete_explicit_checkpoint(
    tmp_path: Path,
) -> None:
    now = datetime.now(timezone.utc)
    with TestClient(app_for(tmp_path / "explicit-delete.sqlite")) as client:
        checkpoint = client.post(
            "/checkpoints",
            json={"title": "Explicit", "summary": "User-saved checkpoint."},
        ).json()
        payload = observation_payload(captured_at=now, allow_public_enrichment=False)
        payload["checkpoint_id"] = checkpoint["id"]
        observation = client.post("/observations", json=payload).json()

        deleted = client.delete(f"/memory/items/{observation['id']}").json()
        assert deleted["checkpoint_deleted"] is False
        assert client.get(f"/checkpoints/{checkpoint['id']}").status_code == 200
        graph = client.get(f"/graph/checkpoints/{checkpoint['id']}").json()
        assert [node["kind"] for node in graph["nodes"]] == ["episode"]


def test_enrichment_observation_must_belong_to_supplied_checkpoint(
    tmp_path: Path,
) -> None:
    now = datetime.now(timezone.utc)
    with TestClient(app_for(tmp_path / "linkage.sqlite")) as client:
        first_checkpoint = client.post(
            "/checkpoints", json={"title": "First", "summary": "First."}
        ).json()
        second_checkpoint = client.post(
            "/checkpoints", json={"title": "Second", "summary": "Second."}
        ).json()
        payload = observation_payload(captured_at=now, allow_public_enrichment=False)
        payload["checkpoint_id"] = first_checkpoint["id"]
        observation = client.post("/observations", json=payload).json()

        response = client.post(
            "/enrichments",
            json={
                "checkpoint_id": second_checkpoint["id"],
                "observation_id": observation["id"],
                "candidate": {
                    "canonical_name": "LiveKit",
                    "kind": "technology",
                    "query": "LiveKit official documentation latest",
                },
            },
        )
        assert response.status_code == 400
        assert response.json() == {"detail": "invalid graph subject"}


def test_additive_migration_adds_observation_link_to_existing_database(
    tmp_path: Path,
) -> None:
    database = tmp_path / "old.sqlite"
    connection = sqlite3.connect(database)
    connection.execute(
        """
        CREATE TABLE enrichment_job (
            id TEXT PRIMARY KEY,
            checkpoint_id TEXT NOT NULL,
            subject_node_id TEXT,
            public_subject TEXT NOT NULL,
            public_query TEXT NOT NULL,
            query_hash TEXT NOT NULL,
            policy_result TEXT NOT NULL,
            policy_reason TEXT NOT NULL,
            status TEXT NOT NULL,
            result_json TEXT NOT NULL DEFAULT '[]',
            created_at TEXT NOT NULL,
            checked_at TEXT NOT NULL,
            expires_at TEXT NOT NULL
        )
        """
    )
    connection.commit()
    connection.close()

    with TestClient(app_for(database)) as client:
        assert client.get("/memory/stats").status_code == 200
    reopened = sqlite3.connect(database)
    columns = {row[1] for row in reopened.execute("PRAGMA table_info(enrichment_job)")}
    reopened.close()
    assert "observation_id" in columns
