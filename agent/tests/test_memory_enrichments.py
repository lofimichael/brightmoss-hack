from __future__ import annotations

import json
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

from fastapi.testclient import TestClient

from checkpoint_agent.freshness import UnavailableSavedURLFetcher
from checkpoint_agent.planner import DeterministicPlanner
from checkpoint_agent.retrieval import UnavailableSearchIndex
from checkpoint_agent.server import create_app


def app_for(database: Path, *, token: str | None = None):
    return create_app(
        database_path=str(database),
        index=UnavailableSearchIndex(),
        planner=DeterministicPlanner(),
        fetcher=UnavailableSavedURLFetcher(),
        bearer_token=token,
    )


def test_enrichment_ledger_is_complete_private_and_deletion_aware(
    tmp_path: Path,
) -> None:
    database = tmp_path / "ledger.sqlite"
    application = app_for(database)
    captured_at = datetime(2026, 7, 18, 20, 0, tzinfo=timezone.utc)
    with TestClient(application) as client:
        checkpoint = client.post(
            "/checkpoints", json={"title": "Research", "summary": "Local work."}
        ).json()
        observation_payload = {
            "checkpoint_id": checkpoint["id"],
            "captured_at": captured_at.isoformat(),
            "application_name": "Xcode",
            "window_title": "SecretProject.swift — alice@example.com",
            "document_resource": "/Users/alice/private/SecretProject.swift",
            "extracted_text": "NEVER_RETURN_CAPTURED_TEXT",
            "subjects": [
                {
                    "canonical_name": "LiveKit",
                    "kind": "technology",
                    "keywords": ["NEVER_RETURN_KEYWORD"],
                }
            ],
        }
        observation = client.post("/observations", json=observation_payload).json()
        repository = application.state.runtime.repository
        linked_jobs: list[str] = []
        for status in (
            "complete",
            "cached",
            "failed",
            "provider_unavailable",
            "rate_limited",
            "rejected",
        ):
            job_id = repository.create_enrichment_job(
                checkpoint_id=checkpoint["id"],
                subject_node_id=None,
                public_subject=(
                    "PRIVATE_REJECTED_SUBJECT" if status == "rejected" else "LiveKit"
                ),
                public_query=(
                    "PRIVATE_REJECTED_QUERY"
                    if status == "rejected"
                    else "LiveKit official documentation latest"
                ),
                query_hash=f"hash-{status}",
                policy_result="rejected" if status == "rejected" else "allowed",
                policy_reason=f"reason-{status}",
                status=status,
                observation_id=observation["id"],
            )
            linked_jobs.append(job_id)

        sources = [
            {"title": f"Source {number}", "url": f"https://example.com/{number}"}
            for number in range(3)
        ]
        with sqlite3.connect(database) as connection:
            connection.execute(
                "UPDATE enrichment_job SET result_json = ? WHERE id = ?",
                (json.dumps([sources[0], {"bad": True}, *sources[1:]]), linked_jobs[0]),
            )

        manual_job = repository.create_enrichment_job(
            checkpoint_id=checkpoint["id"],
            subject_node_id=None,
            public_subject="Moss",
            public_query="Moss official product information latest",
            query_hash="manual",
            policy_result="allowed",
            policy_reason="manual",
            status="complete",
        )
        malformed_job = repository.create_enrichment_job(
            checkpoint_id=checkpoint["id"],
            subject_node_id=None,
            public_subject="OpenAI",
            public_query="OpenAI official company information latest",
            query_hash="legacy",
            policy_result="allowed",
            policy_reason="legacy",
            status="failed",
        )
        with sqlite3.connect(database) as connection:
            connection.execute(
                "UPDATE enrichment_job SET result_json = 'not-json' WHERE id = ?",
                (malformed_job,),
            )

        response = client.get("/memory/enrichments?limit=100")
        assert response.status_code == 200
        payload = response.json()
        assert payload["total"] == 8
        assert {
            "complete",
            "cached",
            "failed",
            "provider_unavailable",
            "rate_limited",
            "rejected",
        } <= {item["status"] for item in payload["items"]}
        serialized = response.text
        assert "NEVER_RETURN_CAPTURED_TEXT" not in serialized
        assert "NEVER_RETURN_KEYWORD" not in serialized
        assert "/Users/alice/private" not in serialized
        rejected = next(
            item for item in payload["items"] if item["status"] == "rejected"
        )
        assert rejected["public_subject"] == "[rejected]"
        assert rejected["outbound_query"] == "[rejected]"
        complete = next(
            item for item in payload["items"] if item["id"] == linked_jobs[0]
        )
        assert complete["source_count"] == 3
        assert len(complete["sources"]) == 2
        assert complete["application_name"] == "Xcode"
        assert complete["document_label"] == "SecretProject.swift"
        assert complete["captured_at"].startswith("2026-07-18T20:00")
        legacy = next(item for item in payload["items"] if item["id"] == malformed_job)
        assert legacy["observation_id"] is None
        assert legacy["sources"] == []
        assert legacy["checkpoint_title"] == "Research"

        assert client.delete(f"/memory/items/{observation['id']}").status_code == 200
        remaining = client.get("/memory/enrichments?limit=100").json()
        assert remaining["total"] == 2
        assert {item["id"] for item in remaining["items"]} == {
            manual_job,
            malformed_job,
        }


def test_enrichment_ledger_compound_cursor_and_auth(tmp_path: Path) -> None:
    database = tmp_path / "paging.sqlite"
    application = app_for(database, token="test-token")
    headers = {"Authorization": "Bearer test-token"}
    with TestClient(application) as client:
        assert client.get("/memory/enrichments").status_code == 401
        checkpoint = client.post(
            "/checkpoints",
            json={"title": "Cursor", "summary": "Cursor test."},
            headers=headers,
        ).json()
        repository = application.state.runtime.repository
        job_ids = [
            repository.create_enrichment_job(
                checkpoint_id=checkpoint["id"],
                subject_node_id=None,
                public_subject="LiveKit",
                public_query="LiveKit official documentation latest",
                query_hash=f"cursor-{number}",
                policy_result="allowed",
                policy_reason="test",
                status="complete",
            )
            for number in range(3)
        ]
        tied_at = "2026-07-18T20:00:00+00:00"
        with sqlite3.connect(database) as connection:
            connection.execute("UPDATE enrichment_job SET checked_at = ?", (tied_at,))

        first = client.get(
            "/memory/enrichments", params={"limit": 1}, headers=headers
        ).json()
        assert first["total"] == 3
        assert first["items"][0]["id"] == max(job_ids)
        cursor = first["items"][0]
        second = client.get(
            "/memory/enrichments",
            params={
                "limit": 1,
                "before": cursor["checked_at"],
                "before_id": cursor["id"],
            },
            headers=headers,
        ).json()
        assert second["items"][0]["id"] == sorted(job_ids, reverse=True)[1]
        assert (
            client.get("/memory/enrichments?limit=0", headers=headers).status_code
            == 422
        )
