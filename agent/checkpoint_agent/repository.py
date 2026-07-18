from __future__ import annotations

import hashlib
import json
import os
import re
import sqlite3
from collections.abc import Iterable
from datetime import datetime, timedelta, timezone
from pathlib import Path
from threading import RLock
from urllib.parse import urlsplit
from uuid import uuid4

from .schemas import (
    CheckpointCreate,
    CheckpointRecord,
    EraseRecentResponse,
    GraphEdge,
    GraphEvidence,
    GraphNeighborhood,
    GraphNode,
    InferredIntent,
    LocalSubject,
    MemoryEnrichmentItem,
    MemoryItem,
    MemoryStats,
    MemorySubjectAggregate,
    ObservationCreate,
    ObservationRecord,
    PublicSource,
    SourceReference,
    SourceVersion,
)


_WORD = re.compile(r"[a-z0-9]+")
_STOP_WORDS = {
    "a",
    "about",
    "and",
    "find",
    "for",
    "from",
    "i",
    "in",
    "it",
    "me",
    "my",
    "of",
    "on",
    "please",
    "resume",
    "reopen",
    "restore",
    "the",
    "thing",
    "to",
    "where",
    "with",
}


def _iso_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _utc_iso(value: datetime) -> str:
    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc).isoformat()


def _stem(word: str) -> str:
    for suffix in ("ingly", "edly", "ing", "ed", "es", "s"):
        if word.endswith(suffix) and len(word) - len(suffix) >= 4:
            return word[: -len(suffix)]
    return word


def _tokens(text: str) -> list[str]:
    return [
        _stem(word)
        for word in _WORD.findall(text.casefold())
        if word not in _STOP_WORDS and len(word) > 1
    ]


def _document_label(resource: str | None) -> str | None:
    """Return a consumer-safe local label, never an entire filesystem path."""

    value = (resource or "").strip()
    if not value:
        return None
    parsed = urlsplit(value)
    if parsed.scheme in {"http", "https"}:
        return parsed.hostname
    normalized = value.rstrip("/\\")
    return re.split(r"[/\\]", normalized)[-1] or None


class CheckpointRepository:
    """The only canonical writer for checkpoint content."""

    def __init__(self, database_path: str | Path) -> None:
        self.database_path = str(database_path)
        if self.database_path != ":memory:":
            expanded_path = Path(self.database_path).expanduser()
            expanded_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            os.chmod(expanded_path.parent, 0o700)
            self.database_path = str(expanded_path)
        self._lock = RLock()
        self._connection = sqlite3.connect(self.database_path, check_same_thread=False)
        self._connection.row_factory = sqlite3.Row
        with self._lock:
            self._connection.execute("PRAGMA foreign_keys = ON")
            if self.database_path != ":memory:":
                self._connection.execute("PRAGMA journal_mode = WAL")
                os.chmod(self.database_path, 0o600)
            self._migrate()

    def close(self) -> None:
        with self._lock:
            self._connection.close()

    def _migrate(self) -> None:
        self._connection.executescript(
            """
            CREATE TABLE IF NOT EXISTS checkpoint (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                summary TEXT NOT NULL,
                next_step TEXT,
                status TEXT NOT NULL DEFAULT 'saved',
                created_at TEXT NOT NULL,
                saved_at TEXT NOT NULL,
                payload_json TEXT NOT NULL
            );

            CREATE INDEX IF NOT EXISTS checkpoint_saved_at
                ON checkpoint(saved_at DESC);

            CREATE TABLE IF NOT EXISTS source_version (
                id TEXT PRIMARY KEY,
                checkpoint_id TEXT NOT NULL REFERENCES checkpoint(id) ON DELETE CASCADE,
                canonical_url TEXT NOT NULL,
                fetched_at TEXT NOT NULL,
                body_hash TEXT NOT NULL,
                normalized_text TEXT NOT NULL,
                is_current INTEGER NOT NULL DEFAULT 1
            );

            CREATE INDEX IF NOT EXISTS source_version_lookup
                ON source_version(checkpoint_id, canonical_url, fetched_at DESC);

            CREATE TABLE IF NOT EXISTS observation (
                id TEXT PRIMARY KEY,
                checkpoint_id TEXT NOT NULL REFERENCES checkpoint(id) ON DELETE CASCADE,
                captured_at TEXT NOT NULL,
                app_bundle_id TEXT,
                window_title TEXT,
                document_resource TEXT,
                extracted_text TEXT,
                extraction_method TEXT NOT NULL,
                content_hash TEXT NOT NULL,
                payload_json TEXT NOT NULL
            );

            CREATE INDEX IF NOT EXISTS observation_checkpoint_time
                ON observation(checkpoint_id, captured_at DESC);
            CREATE INDEX IF NOT EXISTS observation_time
                ON observation(captured_at DESC);

            CREATE TABLE IF NOT EXISTS graph_node (
                id TEXT PRIMARY KEY,
                checkpoint_id TEXT NOT NULL REFERENCES checkpoint(id) ON DELETE CASCADE,
                kind TEXT NOT NULL,
                canonical_key TEXT NOT NULL,
                label TEXT NOT NULL,
                searchable_text TEXT NOT NULL,
                sensitivity TEXT NOT NULL,
                confidence REAL NOT NULL,
                properties_json TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                UNIQUE(checkpoint_id, kind, canonical_key)
            );

            CREATE INDEX IF NOT EXISTS graph_node_checkpoint_kind
                ON graph_node(checkpoint_id, kind);

            CREATE TABLE IF NOT EXISTS graph_evidence (
                id TEXT PRIMARY KEY,
                checkpoint_id TEXT NOT NULL REFERENCES checkpoint(id) ON DELETE CASCADE,
                observation_id TEXT REFERENCES observation(id) ON DELETE CASCADE,
                source_kind TEXT NOT NULL,
                source_ref TEXT,
                excerpt TEXT NOT NULL,
                evidence_hash TEXT NOT NULL,
                captured_at TEXT NOT NULL
            );

            CREATE INDEX IF NOT EXISTS graph_evidence_checkpoint_time
                ON graph_evidence(checkpoint_id, captured_at DESC);

            CREATE TABLE IF NOT EXISTS graph_edge (
                id TEXT PRIMARY KEY,
                checkpoint_id TEXT NOT NULL REFERENCES checkpoint(id) ON DELETE CASCADE,
                observation_id TEXT REFERENCES observation(id) ON DELETE CASCADE,
                from_node_id TEXT NOT NULL REFERENCES graph_node(id) ON DELETE CASCADE,
                to_node_id TEXT NOT NULL REFERENCES graph_node(id) ON DELETE CASCADE,
                kind TEXT NOT NULL,
                confidence REAL NOT NULL,
                evidence_id TEXT REFERENCES graph_evidence(id) ON DELETE SET NULL,
                observed_at TEXT NOT NULL,
                UNIQUE(observation_id, from_node_id, to_node_id, kind)
            );

            CREATE INDEX IF NOT EXISTS graph_edge_checkpoint
                ON graph_edge(checkpoint_id, from_node_id, to_node_id);

            CREATE TABLE IF NOT EXISTS enrichment_job (
                id TEXT PRIMARY KEY,
                checkpoint_id TEXT NOT NULL REFERENCES checkpoint(id) ON DELETE CASCADE,
                observation_id TEXT REFERENCES observation(id) ON DELETE CASCADE,
                subject_node_id TEXT REFERENCES graph_node(id) ON DELETE SET NULL,
                public_subject TEXT NOT NULL,
                public_query TEXT NOT NULL,
                query_hash TEXT NOT NULL,
                policy_result TEXT NOT NULL,
                policy_reason TEXT NOT NULL,
                status TEXT NOT NULL,
                network_attempted INTEGER NOT NULL DEFAULT 0,
                result_json TEXT NOT NULL DEFAULT '[]',
                created_at TEXT NOT NULL,
                checked_at TEXT NOT NULL,
                expires_at TEXT NOT NULL
            );

            CREATE INDEX IF NOT EXISTS enrichment_job_cache
                ON enrichment_job(query_hash, status, expires_at DESC);
            """
        )
        # Existing hackathon databases predate per-memory enrichment linkage.
        # Keep the migration additive so old local memories remain readable.
        enrichment_columns = {
            row["name"]
            for row in self._connection.execute("PRAGMA table_info(enrichment_job)")
        }
        if "observation_id" not in enrichment_columns:
            self._connection.execute(
                "ALTER TABLE enrichment_job ADD COLUMN observation_id TEXT"
            )
        if "network_attempted" not in enrichment_columns:
            self._connection.execute(
                """
                ALTER TABLE enrichment_job
                ADD COLUMN network_attempted INTEGER NOT NULL DEFAULT 0
                """
            )
            # Older rows did not carry a dedicated attempt bit. Cached clones
            # are identifiable by their policy reason; conservatively restore
            # only original running/provider-result rows as attempted.
            self._connection.execute(
                """
                UPDATE enrichment_job SET network_attempted = 1
                WHERE status IN ('running', 'complete', 'failed')
                  AND policy_reason != 'recent_attempt_cached'
                """
            )
        self._connection.execute(
            """
            CREATE INDEX IF NOT EXISTS enrichment_job_observation
            ON enrichment_job(observation_id, checked_at DESC)
            """
        )
        self._connection.commit()

    def save(self, draft: CheckpointCreate) -> CheckpointRecord:
        checkpoint_id = draft.id or str(uuid4())
        now = _iso_now()
        payload = {
            "version": 1,
            "artifacts": [
                artifact.model_dump(mode="json") for artifact in draft.artifacts
            ],
        }
        with self._lock:
            existing = self._connection.execute(
                "SELECT created_at FROM checkpoint WHERE id = ?", (checkpoint_id,)
            ).fetchone()
            created_at = existing["created_at"] if existing else now
            self._connection.execute(
                """
                INSERT INTO checkpoint (
                    id, title, summary, next_step, status, created_at, saved_at, payload_json
                ) VALUES (?, ?, ?, ?, 'saved', ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    title = excluded.title,
                    summary = excluded.summary,
                    next_step = excluded.next_step,
                    status = 'saved',
                    saved_at = excluded.saved_at,
                    payload_json = excluded.payload_json
                """,
                (
                    checkpoint_id,
                    draft.title,
                    draft.summary,
                    draft.next_step,
                    created_at,
                    now,
                    json.dumps(payload, ensure_ascii=False, separators=(",", ":")),
                ),
            )
            self._upsert_graph_node_locked(
                checkpoint_id=checkpoint_id,
                kind="episode",
                canonical_key=checkpoint_id,
                label=draft.title,
                searchable_text="\n".join(
                    part
                    for part in (draft.title, draft.summary, draft.next_step or "")
                    if part
                ),
                sensitivity="private",
                confidence=1.0,
                properties={"summary": draft.summary, "next_step": draft.next_step},
                timestamp=now,
            )
            self._connection.commit()
        record = self.get(checkpoint_id)
        if record is None:  # pragma: no cover - protects against disk corruption
            raise RuntimeError("checkpoint was not readable after save")
        return record

    def get(self, checkpoint_id: str) -> CheckpointRecord | None:
        with self._lock:
            row = self._connection.execute(
                "SELECT * FROM checkpoint WHERE id = ? AND status = 'saved'",
                (checkpoint_id,),
            ).fetchone()
        return self._record(row) if row else None

    def list_recent(self, limit: int = 20) -> list[CheckpointRecord]:
        safe_limit = max(1, min(limit, 100))
        with self._lock:
            rows = self._connection.execute(
                """
                SELECT * FROM checkpoint
                WHERE status = 'saved'
                ORDER BY saved_at DESC
                LIMIT ?
                """,
                (safe_limit,),
            ).fetchall()
        return [self._record(row) for row in rows]

    def search(
        self, query: str, limit: int = 5
    ) -> list[tuple[CheckpointRecord, float]]:
        """Rank literal and token-substring matches without a network dependency."""

        normalized_query = " ".join(_WORD.findall(query.casefold()))
        query_tokens = _tokens(query)
        if not normalized_query:
            return []
        candidates = self.list_recent(limit=100)
        graph_context: dict[str, list[str]] = {
            checkpoint.id: [] for checkpoint in candidates
        }
        if candidates:
            checkpoint_ids = [checkpoint.id for checkpoint in candidates]
            placeholders = ",".join("?" for _ in checkpoint_ids)
            with self._lock:
                node_rows = self._connection.execute(
                    f"""
                    SELECT checkpoint_id, label, searchable_text
                    FROM graph_node
                    WHERE checkpoint_id IN ({placeholders})
                    ORDER BY updated_at DESC
                    """,
                    checkpoint_ids,
                ).fetchall()
                evidence_rows = self._connection.execute(
                    f"""
                    SELECT checkpoint_id, excerpt
                    FROM graph_evidence
                    WHERE checkpoint_id IN ({placeholders})
                    ORDER BY captured_at DESC
                    """,
                    checkpoint_ids,
                ).fetchall()
            for row in node_rows:
                current = graph_context[row["checkpoint_id"]]
                if sum(map(len, current)) < 20_000:
                    current.extend((row["label"], row["searchable_text"]))
            for row in evidence_rows:
                current = graph_context[row["checkpoint_id"]]
                if sum(map(len, current)) < 20_000:
                    current.append(row["excerpt"])
        scored: list[tuple[CheckpointRecord, float]] = []
        for checkpoint in candidates:
            title = checkpoint.title.casefold()
            summary = checkpoint.summary.casefold()
            next_step = (checkpoint.next_step or "").casefold()
            artifact_text = " ".join(
                " ".join(
                    value
                    for value in (
                        artifact.display_name,
                        artifact.resource or "",
                        artifact.captured_text or "",
                    )
                    if value
                )
                for artifact in checkpoint.artifacts
            ).casefold()
            graph_text = " ".join(graph_context[checkpoint.id]).casefold()
            full_text = f"{title} {summary} {next_step} {artifact_text} {graph_text}"
            score = 0.0
            if normalized_query in full_text:
                score += 100.0
            for token in query_tokens:
                if token in title:
                    score += 12.0
                if token in summary:
                    score += 7.0
                if token in next_step:
                    score += 7.0
                if token in artifact_text:
                    score += 3.0
                if token in graph_text:
                    score += 5.0
            if score > 0:
                scored.append((checkpoint, score))
        scored.sort(key=lambda item: (item[1], item[0].saved_at), reverse=True)
        return scored[: max(1, min(limit, 20))]

    def delete(self, checkpoint_id: str) -> bool:
        with self._lock:
            cursor = self._connection.execute(
                "DELETE FROM checkpoint WHERE id = ?", (checkpoint_id,)
            )
            self._connection.commit()
            return cursor.rowcount > 0

    def save_observation(self, draft: ObservationCreate) -> ObservationRecord:
        """Persist one already-local, structured observation and its graph facts."""

        observation_id = draft.id or str(uuid4())
        captured_at = _utc_iso(draft.captured_at)
        extracted_text = (draft.extracted_text or "").strip()
        fingerprint_payload = {
            "application_name": draft.application_name,
            "app_bundle_id": draft.app_bundle_id,
            "window_title": draft.window_title,
            "document_resource": draft.document_resource,
            "extracted_text": extracted_text,
            "subjects": [item.model_dump(mode="json") for item in draft.subjects],
            "likely_intent": (
                draft.likely_intent.model_dump(mode="json")
                if draft.likely_intent
                else None
            ),
        }
        content_hash = hashlib.sha256(
            json.dumps(
                fingerprint_payload,
                ensure_ascii=False,
                sort_keys=True,
                separators=(",", ":"),
            ).encode("utf-8")
        ).hexdigest()
        evidence_excerpt = extracted_text[:4_000] or " · ".join(
            part
            for part in (
                draft.window_title,
                draft.application_name,
                draft.app_bundle_id,
                draft.document_resource,
            )
            if part
        )
        if not evidence_excerpt:
            evidence_excerpt = "Foreground state observed."
        subject_keywords = list(
            dict.fromkeys(
                keyword
                for subject in draft.subjects
                for keyword in subject.keywords
                if keyword
            )
        )
        if subject_keywords:
            evidence_excerpt = (
                f"{evidence_excerpt}\nKeywords: {', '.join(subject_keywords)}"
            )[:4_000]
        evidence_id = str(uuid4())
        node_ids: list[str] = []

        with self._lock:
            checkpoint = self._connection.execute(
                "SELECT title, summary, next_step FROM checkpoint WHERE id = ?",
                (draft.checkpoint_id,),
            ).fetchone()
            if checkpoint is None:
                raise KeyError(draft.checkpoint_id)
            self._connection.execute(
                """
                INSERT INTO observation (
                    id, checkpoint_id, captured_at, app_bundle_id, window_title,
                    document_resource, extracted_text, extraction_method,
                    content_hash, payload_json
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    observation_id,
                    draft.checkpoint_id,
                    captured_at,
                    draft.app_bundle_id,
                    draft.window_title,
                    draft.document_resource,
                    extracted_text or None,
                    str(draft.extraction_method),
                    content_hash,
                    json.dumps(
                        fingerprint_payload,
                        ensure_ascii=False,
                        separators=(",", ":"),
                    ),
                ),
            )
            self._connection.execute(
                """
                INSERT INTO graph_evidence (
                    id, checkpoint_id, observation_id, source_kind, source_ref,
                    excerpt, evidence_hash, captured_at
                ) VALUES (?, ?, ?, 'local_observation', ?, ?, ?, ?)
                """,
                (
                    evidence_id,
                    draft.checkpoint_id,
                    observation_id,
                    draft.document_resource or draft.app_bundle_id,
                    evidence_excerpt,
                    hashlib.sha256(evidence_excerpt.encode("utf-8")).hexdigest(),
                    captured_at,
                ),
            )
            episode_id = self._upsert_graph_node_locked(
                checkpoint_id=draft.checkpoint_id,
                kind="episode",
                canonical_key=draft.checkpoint_id,
                label=checkpoint["title"],
                searchable_text="\n".join(
                    part
                    for part in (
                        checkpoint["title"],
                        checkpoint["summary"],
                        checkpoint["next_step"] or "",
                    )
                    if part
                ),
                sensitivity="private",
                confidence=1.0,
                properties={},
                timestamp=captured_at,
            )
            node_ids.append(episode_id)

            if draft.app_bundle_id:
                app_id = self._upsert_graph_node_locked(
                    checkpoint_id=draft.checkpoint_id,
                    kind="artifact",
                    canonical_key=f"app:{draft.app_bundle_id.casefold()}",
                    label=draft.app_bundle_id,
                    searchable_text=" ".join(
                        part
                        for part in (draft.app_bundle_id, draft.window_title or "")
                        if part
                    ),
                    sensitivity="private",
                    confidence=1.0,
                    properties={"artifact_kind": "app"},
                    timestamp=captured_at,
                )
                node_ids.append(app_id)
                self._insert_graph_edge_locked(
                    checkpoint_id=draft.checkpoint_id,
                    observation_id=observation_id,
                    from_node_id=episode_id,
                    to_node_id=app_id,
                    kind="USED",
                    confidence=1.0,
                    evidence_id=evidence_id,
                    observed_at=captured_at,
                )

            if draft.document_resource:
                resource_key = hashlib.sha256(
                    draft.document_resource.encode("utf-8")
                ).hexdigest()
                resource_id = self._upsert_graph_node_locked(
                    checkpoint_id=draft.checkpoint_id,
                    kind="artifact",
                    canonical_key=f"resource:{resource_key}",
                    label=(draft.window_title or draft.document_resource)[-500:],
                    searchable_text="\n".join(
                        part
                        for part in (
                            draft.window_title or "",
                            draft.document_resource,
                            extracted_text[:2_000],
                        )
                        if part
                    ),
                    sensitivity="private",
                    confidence=1.0,
                    properties={
                        "artifact_kind": (
                            "url"
                            if draft.document_resource.startswith("https://")
                            else "file"
                        )
                    },
                    timestamp=captured_at,
                )
                node_ids.append(resource_id)
                self._insert_graph_edge_locked(
                    checkpoint_id=draft.checkpoint_id,
                    observation_id=observation_id,
                    from_node_id=episode_id,
                    to_node_id=resource_id,
                    kind="USED",
                    confidence=1.0,
                    evidence_id=evidence_id,
                    observed_at=captured_at,
                )

            for subject in draft.subjects:
                subject_key = hashlib.sha256(
                    f"{subject.kind}:{subject.canonical_name.casefold()}".encode()
                ).hexdigest()
                subject_id = self._upsert_graph_node_locked(
                    checkpoint_id=draft.checkpoint_id,
                    kind="entity",
                    canonical_key=f"subject:{subject_key}",
                    label=subject.canonical_name,
                    searchable_text="\n".join(
                        part
                        for part in (
                            subject.canonical_name,
                            *subject.keywords,
                            extracted_text[:2_000],
                        )
                        if part
                    ),
                    sensitivity="private",
                    confidence=subject.confidence,
                    properties={
                        "subject_kind": str(subject.kind),
                        "keywords": subject.keywords,
                    },
                    timestamp=captured_at,
                )
                node_ids.append(subject_id)
                self._insert_graph_edge_locked(
                    checkpoint_id=draft.checkpoint_id,
                    observation_id=observation_id,
                    from_node_id=episode_id,
                    to_node_id=subject_id,
                    kind="ABOUT",
                    confidence=subject.confidence,
                    evidence_id=evidence_id,
                    observed_at=captured_at,
                )

            if draft.likely_intent:
                intent_key = hashlib.sha256(
                    draft.likely_intent.summary.casefold().encode("utf-8")
                ).hexdigest()
                intent_id = self._upsert_graph_node_locked(
                    checkpoint_id=draft.checkpoint_id,
                    kind="intent",
                    canonical_key=f"intent:{intent_key}",
                    label=draft.likely_intent.summary,
                    searchable_text=draft.likely_intent.summary,
                    sensitivity="private",
                    confidence=draft.likely_intent.confidence,
                    properties={"inferred": True},
                    timestamp=captured_at,
                )
                node_ids.append(intent_id)
                self._insert_graph_edge_locked(
                    checkpoint_id=draft.checkpoint_id,
                    observation_id=observation_id,
                    from_node_id=episode_id,
                    to_node_id=intent_id,
                    kind="INFERRED_INTENT",
                    confidence=draft.likely_intent.confidence,
                    evidence_id=evidence_id,
                    observed_at=captured_at,
                )
            self._connection.commit()

        return ObservationRecord(
            id=observation_id,
            checkpoint_id=draft.checkpoint_id,
            captured_at=captured_at,
            content_hash=content_hash,
            extraction_method=draft.extraction_method,
            node_ids=list(dict.fromkeys(node_ids)),
            evidence_id=evidence_id,
        )

    def list_memory_items(
        self,
        *,
        limit: int = 50,
        before: datetime | None = None,
        before_id: str | None = None,
    ) -> tuple[list[MemoryItem], int]:
        """Return a paginated local timeline without exposing full path labels."""

        safe_limit = max(1, min(limit, 100))
        where = ""
        parameters: list[object] = []
        if before is not None and before_id is not None:
            where = "WHERE (o.captured_at < ? OR (o.captured_at = ? AND o.id < ?))"
            cursor = _utc_iso(before)
            parameters.extend((cursor, cursor, before_id))
        elif before is not None:
            where = "WHERE o.captured_at < ?"
            parameters.append(_utc_iso(before))
        parameters.append(safe_limit)
        with self._lock:
            total = int(
                self._connection.execute(
                    "SELECT COUNT(*) AS count FROM observation"
                ).fetchone()["count"]
            )
            rows = self._connection.execute(
                f"""
                SELECT o.*,
                       j.status AS enrichment_status,
                       j.public_query AS outbound_query,
                       j.result_json AS enrichment_results
                FROM observation o
                LEFT JOIN enrichment_job j ON j.id = (
                    SELECT candidate.id
                    FROM enrichment_job candidate
                    WHERE candidate.observation_id = o.id
                    ORDER BY candidate.checked_at DESC, candidate.created_at DESC
                    LIMIT 1
                )
                {where}
                ORDER BY o.captured_at DESC, o.id DESC
                LIMIT ?
                """,
                parameters,
            ).fetchall()
        return [self._memory_item(row) for row in rows], total

    def list_memory_enrichments(
        self,
        *,
        limit: int = 50,
        before: datetime | None = None,
        before_id: str | None = None,
    ) -> tuple[list[MemoryEnrichmentItem], int]:
        """Return public-enrichment activity without local captured content."""

        safe_limit = max(1, min(limit, 100))
        where = ""
        parameters: list[object] = []
        if before is not None and before_id is not None:
            where = "WHERE (j.checked_at < ? OR (j.checked_at = ? AND j.id < ?))"
            cursor = _utc_iso(before)
            parameters.extend((cursor, cursor, before_id))
        elif before is not None:
            where = "WHERE j.checked_at < ?"
            parameters.append(_utc_iso(before))
        parameters.append(safe_limit)
        with self._lock:
            total = int(
                self._connection.execute(
                    "SELECT COUNT(*) AS count FROM enrichment_job"
                ).fetchone()["count"]
            )
            rows = self._connection.execute(
                f"""
                SELECT j.*,
                       c.title AS checkpoint_title,
                       c.saved_at AS checkpoint_saved_at,
                       o.captured_at AS observation_captured_at,
                       o.window_title AS origin_window_title,
                       o.document_resource AS origin_document_resource,
                       o.payload_json AS observation_payload_json
                FROM enrichment_job j
                JOIN checkpoint c ON c.id = j.checkpoint_id
                LEFT JOIN observation o
                  ON o.id = j.observation_id
                 AND o.checkpoint_id = j.checkpoint_id
                {where}
                ORDER BY j.checked_at DESC, j.id DESC
                LIMIT ?
                """,
                parameters,
            ).fetchall()
        return [self._memory_enrichment(row) for row in rows], total

    def memory_subjects(
        self, *, limit: int = 50
    ) -> tuple[list[MemorySubjectAggregate], int]:
        safe_limit = max(1, min(limit, 100))
        with self._lock:
            aggregates = self._subject_aggregates_locked()
        aggregates.sort(
            key=lambda item: (
                item.count,
                item.last_seen,
                item.canonical_name.casefold(),
            ),
            reverse=True,
        )
        return aggregates[:safe_limit], len(aggregates)

    def memory_stats(self) -> MemoryStats:
        with self._lock:
            total_memories = self._count_locked("observation")
            aggregates = self._subject_aggregates_locked()
            enriched_memories = int(
                self._connection.execute(
                    """
                    SELECT COUNT(DISTINCT observation_id) AS count
                    FROM enrichment_job
                    WHERE observation_id IS NOT NULL
                      AND status IN ('complete', 'cached')
                      AND result_json != '[]'
                    """
                ).fetchone()["count"]
            )
            source_rows = self._connection.execute(
                """
                SELECT result_json FROM enrichment_job
                WHERE status IN ('complete', 'cached')
                """
            ).fetchall()
        source_urls = {
            source.get("url")
            for row in source_rows
            for source in json.loads(row["result_json"] or "[]")
            if source.get("url")
        }
        categories: dict[str, int] = {}
        for aggregate in aggregates:
            kind = str(aggregate.kind)
            categories[kind] = categories.get(kind, 0) + aggregate.count
        return MemoryStats(
            total_memories=total_memories,
            total_subjects=len(aggregates),
            enriched_memories=enriched_memories,
            public_sources=len(source_urls),
            categories=categories,
        )

    def memory_checkpoint_id(self, observation_id: str) -> str | None:
        with self._lock:
            row = self._connection.execute(
                "SELECT checkpoint_id FROM observation WHERE id = ?", (observation_id,)
            ).fetchone()
        return str(row["checkpoint_id"]) if row else None

    def private_subject_node_for_observation(
        self,
        *,
        checkpoint_id: str,
        observation_id: str,
        canonical_name: str,
        subject_kind: str,
    ) -> str | None:
        """Resolve the private entity already created from this observation."""

        subject_hash = hashlib.sha256(
            f"{subject_kind}:{canonical_name.casefold()}".encode()
        ).hexdigest()
        canonical_key = f"subject:{subject_hash}"
        with self._lock:
            row = self._connection.execute(
                """
                SELECT n.id
                FROM graph_node n
                JOIN graph_edge e
                  ON e.to_node_id = n.id
                 AND e.observation_id = ?
                 AND e.kind = 'ABOUT'
                WHERE n.checkpoint_id = ?
                  AND n.kind = 'entity'
                  AND n.sensitivity = 'private'
                  AND n.canonical_key = ?
                LIMIT 1
                """,
                (observation_id, checkpoint_id, canonical_key),
            ).fetchone()
        return str(row["id"]) if row else None

    def public_context_resources(
        self, checkpoint_id: str, *, observation_id: str | None = None
    ) -> list[str]:
        """Return locally saved URL candidates for public-label corroboration."""

        with self._lock:
            checkpoint = self._connection.execute(
                "SELECT payload_json FROM checkpoint WHERE id = ?", (checkpoint_id,)
            ).fetchone()
            if observation_id is not None:
                observation_rows = self._connection.execute(
                    """
                    SELECT document_resource FROM observation
                    WHERE id = ? AND checkpoint_id = ?
                    """,
                    (observation_id, checkpoint_id),
                ).fetchall()
            else:
                observation_rows = self._connection.execute(
                    """
                    SELECT document_resource FROM observation
                    WHERE checkpoint_id = ?
                    """,
                    (checkpoint_id,),
                ).fetchall()
        resources = [
            str(row["document_resource"])
            for row in observation_rows
            if row["document_resource"]
        ]
        if checkpoint is not None:
            try:
                payload = json.loads(checkpoint["payload_json"] or "{}")
            except (json.JSONDecodeError, TypeError):
                payload = {}
            if isinstance(payload, dict):
                artifacts = payload.get("artifacts", [])
                if isinstance(artifacts, list):
                    resources.extend(
                        str(artifact["resource"])
                        for artifact in artifacts
                        if isinstance(artifact, dict) and artifact.get("resource")
                    )
        return list(dict.fromkeys(resources))

    def delete_memory_item(self, observation_id: str) -> tuple[bool, bool]:
        """Delete one observation plus only graph/provenance derived from it."""

        with self._lock:
            row = self._connection.execute(
                "SELECT checkpoint_id FROM observation WHERE id = ?", (observation_id,)
            ).fetchone()
            if row is None:
                return False, False
            checkpoint_id = str(row["checkpoint_id"])
            # Migrated databases do not have an SQLite FK on the added column,
            # so make the linkage deletion explicit as well as cascade-safe.
            self._connection.execute(
                "DELETE FROM enrichment_job WHERE observation_id = ?",
                (observation_id,),
            )
            self._connection.execute(
                "DELETE FROM observation WHERE id = ?", (observation_id,)
            )
            remaining = int(
                self._connection.execute(
                    "SELECT COUNT(*) AS count FROM observation WHERE checkpoint_id = ?",
                    (checkpoint_id,),
                ).fetchone()["count"]
            )
            checkpoint_deleted = checkpoint_id.startswith("ambient-") and remaining == 0
            if checkpoint_deleted:
                self._connection.execute(
                    "DELETE FROM checkpoint WHERE id = ?", (checkpoint_id,)
                )
            else:
                self._connection.execute(
                    """
                    DELETE FROM graph_node
                    WHERE checkpoint_id = ? AND kind != 'episode'
                      AND NOT EXISTS (
                          SELECT 1 FROM graph_edge
                          WHERE from_node_id = graph_node.id
                             OR to_node_id = graph_node.id
                      )
                    """,
                    (checkpoint_id,),
                )
                self._refresh_private_subject_nodes_locked(checkpoint_id)
                self._refresh_private_artifact_nodes_locked(checkpoint_id)
                if checkpoint_id.startswith("ambient-"):
                    self._refresh_ambient_checkpoint_locked(checkpoint_id)
            self._connection.commit()
        return True, checkpoint_deleted

    def _refresh_private_subject_nodes_locked(self, checkpoint_id: str) -> None:
        rows = self._connection.execute(
            """
            SELECT extracted_text, payload_json FROM observation
            WHERE checkpoint_id = ? ORDER BY captured_at DESC
            """,
            (checkpoint_id,),
        ).fetchall()
        aggregates: dict[str, dict] = {}
        for row in rows:
            payload = json.loads(row["payload_json"] or "{}")
            for raw_subject in payload.get("subjects", []):
                subject = LocalSubject.model_validate(raw_subject)
                subject_hash = hashlib.sha256(
                    f"{subject.kind}:{subject.canonical_name.casefold()}".encode()
                ).hexdigest()
                key = f"subject:{subject_hash}"
                value = aggregates.setdefault(
                    key,
                    {
                        "label": subject.canonical_name,
                        "kind": str(subject.kind),
                        "confidence": subject.confidence,
                        "parts": [],
                        "keywords": set(),
                    },
                )
                value["confidence"] = max(value["confidence"], subject.confidence)
                value["keywords"].update(subject.keywords)
                value["parts"].extend(
                    [
                        subject.canonical_name,
                        *subject.keywords,
                        row["extracted_text"] or "",
                    ]
                )
        for canonical_key, value in aggregates.items():
            searchable = "\n".join(
                dict.fromkeys(part for part in value["parts"] if part)
            )[:4_000]
            self._connection.execute(
                """
                UPDATE graph_node
                SET label = ?, searchable_text = ?, confidence = ?,
                    properties_json = ?, updated_at = ?
                WHERE checkpoint_id = ? AND kind = 'entity'
                  AND sensitivity = 'private' AND canonical_key = ?
                """,
                (
                    value["label"][:500],
                    searchable,
                    value["confidence"],
                    json.dumps(
                        {
                            "subject_kind": value["kind"],
                            "keywords": sorted(value["keywords"], key=str.casefold),
                        },
                        ensure_ascii=False,
                        separators=(",", ":"),
                    ),
                    _iso_now(),
                    checkpoint_id,
                    canonical_key,
                ),
            )

    def _refresh_private_artifact_nodes_locked(self, checkpoint_id: str) -> None:
        """Rebuild shared app/resource text solely from surviving observations."""

        rows = self._connection.execute(
            """
            SELECT captured_at, app_bundle_id, window_title, document_resource,
                   extracted_text
            FROM observation
            WHERE checkpoint_id = ?
            ORDER BY captured_at DESC, id DESC
            """,
            (checkpoint_id,),
        ).fetchall()
        aggregates: dict[str, dict] = {}
        for row in rows:
            bundle_id = row["app_bundle_id"]
            if bundle_id:
                key = f"app:{str(bundle_id).casefold()}"
                value = aggregates.setdefault(
                    key,
                    {
                        "label": str(bundle_id),
                        "parts": [],
                        "properties": {"artifact_kind": "app"},
                    },
                )
                value["parts"].extend((bundle_id, row["window_title"] or ""))

            resource = row["document_resource"]
            if resource:
                resource_hash = hashlib.sha256(
                    str(resource).encode("utf-8")
                ).hexdigest()
                key = f"resource:{resource_hash}"
                value = aggregates.setdefault(
                    key,
                    {
                        # Rows are newest-first, so this label is the latest
                        # surviving title rather than deleted capture state.
                        "label": (row["window_title"] or resource)[-500:],
                        "parts": [],
                        "properties": {
                            "artifact_kind": (
                                "url"
                                if str(resource).startswith("https://")
                                else "file"
                            )
                        },
                    },
                )
                value["parts"].extend(
                    (
                        row["window_title"] or "",
                        resource,
                        (row["extracted_text"] or "")[:2_000],
                    )
                )

        for canonical_key, value in aggregates.items():
            searchable = "\n".join(
                dict.fromkeys(str(part) for part in value["parts"] if part)
            )[:4_000]
            self._connection.execute(
                """
                UPDATE graph_node
                SET label = ?, searchable_text = ?, properties_json = ?, updated_at = ?
                WHERE checkpoint_id = ? AND kind = 'artifact'
                  AND sensitivity = 'private' AND canonical_key = ?
                """,
                (
                    value["label"],
                    searchable,
                    json.dumps(
                        value["properties"],
                        ensure_ascii=False,
                        separators=(",", ":"),
                    ),
                    _iso_now(),
                    checkpoint_id,
                    canonical_key,
                ),
            )

    def _refresh_ambient_checkpoint_locked(self, checkpoint_id: str) -> None:
        rows = self._connection.execute(
            """
            SELECT * FROM observation
            WHERE checkpoint_id = ?
            ORDER BY captured_at DESC
            """,
            (checkpoint_id,),
        ).fetchall()
        if not rows:
            return
        latest_payload = json.loads(rows[0]["payload_json"] or "{}")
        intent = latest_payload.get("likely_intent") or {}
        subjects = latest_payload.get("subjects") or []
        summary = intent.get("summary")
        if not summary and subjects:
            summary = "Working with " + ", ".join(
                subject.get("canonical_name", "") for subject in subjects[:3]
            )
        summary = summary or rows[0]["window_title"] or "Earlier workspace context."

        artifacts: list[dict] = []
        seen: set[tuple[str, str]] = set()
        for observation in rows:
            payload = json.loads(observation["payload_json"] or "{}")
            app_name = payload.get("application_name")
            if app_name or observation["app_bundle_id"]:
                identity = observation["app_bundle_id"] or app_name
                key = ("app", str(identity))
                if key not in seen:
                    seen.add(key)
                    title = observation["window_title"]
                    artifacts.append(
                        {
                            "id": str(uuid4()),
                            "kind": "app",
                            "display_name": (
                                f"{app_name} — {title}"
                                if app_name and title
                                else app_name or identity
                            ),
                            "bundle_id": observation["app_bundle_id"],
                            "captured_text": title,
                            "captured_at": observation["captured_at"],
                        }
                    )
            resource = observation["document_resource"]
            if resource:
                artifact_kind = "url" if resource.startswith("https://") else "file"
                key = (artifact_kind, resource)
                if key not in seen:
                    seen.add(key)
                    artifacts.append(
                        {
                            "id": str(uuid4()),
                            "kind": artifact_kind,
                            "display_name": observation["window_title"]
                            or _document_label(resource)
                            or "Document",
                            "resource": resource,
                            "captured_text": observation["window_title"],
                            "captured_at": observation["captured_at"],
                        }
                    )
            if len(artifacts) >= 8:
                break
        payload_json = json.dumps(
            {"version": 1, "artifacts": artifacts[:8]},
            ensure_ascii=False,
            separators=(",", ":"),
        )
        self._connection.execute(
            """
            UPDATE checkpoint SET summary = ?, saved_at = ?, payload_json = ?
            WHERE id = ?
            """,
            (str(summary)[:500], rows[0]["captured_at"], payload_json, checkpoint_id),
        )
        checkpoint = self._connection.execute(
            "SELECT title FROM checkpoint WHERE id = ?", (checkpoint_id,)
        ).fetchone()
        if checkpoint:
            self._upsert_graph_node_locked(
                checkpoint_id=checkpoint_id,
                kind="episode",
                canonical_key=checkpoint_id,
                label=checkpoint["title"],
                searchable_text=f"{checkpoint['title']}\n{summary}",
                sensitivity="private",
                confidence=1.0,
                properties={"summary": summary, "next_step": None},
                timestamp=rows[0]["captured_at"],
            )

    @staticmethod
    def _memory_item(row: sqlite3.Row) -> MemoryItem:
        payload = json.loads(row["payload_json"] or "{}")
        sources = [
            PublicSource.model_validate(source)
            for source in json.loads(row["enrichment_results"] or "[]")
        ]
        intent_payload = payload.get("likely_intent")
        return MemoryItem(
            id=row["id"],
            checkpoint_id=row["checkpoint_id"],
            captured_at=row["captured_at"],
            application_name=payload.get("application_name"),
            app_bundle_id=row["app_bundle_id"],
            window_title=row["window_title"],
            document_label=_document_label(row["document_resource"]),
            extraction_method=row["extraction_method"],
            subjects=[
                LocalSubject.model_validate(subject)
                for subject in payload.get("subjects", [])
            ],
            likely_intent=(
                InferredIntent.model_validate(intent_payload)
                if intent_payload
                else None
            ),
            public_sources=sources,
            enrichment_status=row["enrichment_status"],
            outbound_query=(
                None
                if row["enrichment_status"] == "rejected"
                else row["outbound_query"]
            ),
            provenance=["local", *(["bright_data"] if sources else [])],
        )

    @staticmethod
    def _memory_enrichment(row: sqlite3.Row) -> MemoryEnrichmentItem:
        try:
            raw_sources: object = json.loads(row["result_json"] or "[]")
        except (json.JSONDecodeError, TypeError):
            raw_sources = []
        parsed_sources: list[PublicSource] = []
        if isinstance(raw_sources, list):
            for raw_source in raw_sources:
                try:
                    parsed_sources.append(PublicSource.model_validate(raw_source))
                except (TypeError, ValueError):
                    continue

        try:
            payload: object = json.loads(row["observation_payload_json"] or "{}")
        except (json.JSONDecodeError, TypeError):
            payload = {}
        if not isinstance(payload, dict):
            payload = {}

        rejected = row["status"] == "rejected" or row["policy_result"] == "rejected"
        redacted_marker = "[rejected]"
        return MemoryEnrichmentItem(
            id=row["id"],
            job_id=row["id"],
            checkpoint_id=row["checkpoint_id"],
            checkpoint_title=row["checkpoint_title"],
            observation_id=row["observation_id"],
            checked_at=row["checked_at"],
            public_subject=(redacted_marker if rejected else row["public_subject"]),
            outbound_query=(redacted_marker if rejected else row["public_query"]),
            status=row["status"],
            policy=row["policy_result"],
            policy_reason=row["policy_reason"],
            sources=parsed_sources[:2],
            source_count=len(parsed_sources),
            captured_at=(row["observation_captured_at"] or row["checkpoint_saved_at"]),
            application_name=payload.get("application_name"),
            window_title=row["origin_window_title"],
            document_label=_document_label(row["origin_document_resource"]),
        )

    def _subject_aggregates_locked(self) -> list[MemorySubjectAggregate]:
        rows = self._connection.execute(
            "SELECT captured_at, payload_json FROM observation ORDER BY captured_at ASC"
        ).fetchall()
        values: dict[tuple[str, str], dict] = {}
        for row in rows:
            payload = json.loads(row["payload_json"] or "{}")
            application = (payload.get("application_name") or "").strip()
            seen_in_observation: set[tuple[str, str]] = set()
            for raw_subject in payload.get("subjects", []):
                subject = LocalSubject.model_validate(raw_subject)
                key = (str(subject.kind), subject.canonical_name.casefold())
                if key in seen_in_observation:
                    continue
                seen_in_observation.add(key)
                aggregate = values.setdefault(
                    key,
                    {
                        "canonical_name": subject.canonical_name,
                        "kind": subject.kind,
                        "keywords": set(),
                        "count": 0,
                        "first_seen": row["captured_at"],
                        "last_seen": row["captured_at"],
                        "apps": set(),
                        "sources": {},
                    },
                )
                aggregate["count"] += 1
                aggregate["last_seen"] = row["captured_at"]
                aggregate["keywords"].update(subject.keywords)
                if application:
                    aggregate["apps"].add(application)

        source_rows = self._connection.execute(
            """
            SELECT public_subject, result_json
            FROM enrichment_job
            WHERE status IN ('complete', 'cached') AND result_json != '[]'
            ORDER BY checked_at DESC
            """
        ).fetchall()
        for row in source_rows:
            subject_name = row["public_subject"].casefold()
            matching = [key for key in values if key[1] == subject_name]
            for key in matching:
                for raw_source in json.loads(row["result_json"] or "[]"):
                    source = PublicSource.model_validate(raw_source)
                    values[key]["sources"].setdefault(source.url, source)

        return [
            MemorySubjectAggregate(
                canonical_name=value["canonical_name"],
                kind=value["kind"],
                keywords=sorted(value["keywords"], key=str.casefold)[:12],
                count=value["count"],
                first_seen=value["first_seen"],
                last_seen=value["last_seen"],
                apps=sorted(value["apps"], key=str.casefold)[:12],
                public_sources=list(value["sources"].values())[:2],
            )
            for value in values.values()
        ]

    def graph_neighborhood(
        self, checkpoint_id: str, *, limit: int = 100
    ) -> GraphNeighborhood | None:
        safe_limit = max(1, min(limit, 200))
        with self._lock:
            exists = self._connection.execute(
                "SELECT 1 FROM checkpoint WHERE id = ?", (checkpoint_id,)
            ).fetchone()
            if exists is None:
                return None
            node_rows = self._connection.execute(
                """
                SELECT * FROM graph_node
                WHERE checkpoint_id = ?
                ORDER BY updated_at DESC
                LIMIT ?
                """,
                (checkpoint_id, safe_limit),
            ).fetchall()
            node_ids = [row["id"] for row in node_rows]
            if node_ids:
                placeholders = ",".join("?" for _ in node_ids)
                edge_rows = self._connection.execute(
                    f"""
                    SELECT * FROM graph_edge
                    WHERE checkpoint_id = ?
                      AND from_node_id IN ({placeholders})
                      AND to_node_id IN ({placeholders})
                    ORDER BY observed_at DESC
                    LIMIT ?
                    """,
                    (checkpoint_id, *node_ids, *node_ids, safe_limit * 2),
                ).fetchall()
                evidence_ids = list(
                    dict.fromkeys(
                        row["evidence_id"] for row in edge_rows if row["evidence_id"]
                    )
                )
            else:
                edge_rows = []
                evidence_ids = []
            if evidence_ids:
                evidence_placeholders = ",".join("?" for _ in evidence_ids)
                evidence_rows = self._connection.execute(
                    f"SELECT * FROM graph_evidence WHERE id IN ({evidence_placeholders})",
                    evidence_ids,
                ).fetchall()
            else:
                evidence_rows = []
        return GraphNeighborhood(
            checkpoint_id=checkpoint_id,
            nodes=[self._graph_node(row) for row in node_rows],
            edges=[self._graph_edge(row) for row in edge_rows],
            evidence=[self._graph_evidence(row) for row in evidence_rows],
        )

    def graph_documents(self, checkpoint_id: str | None = None) -> list[dict]:
        """Build compact retrieval documents; traversal stays in SQLite."""

        with self._lock:
            parameters: tuple[str, ...] = ()
            where = ""
            if checkpoint_id is not None:
                where = "WHERE n.checkpoint_id = ?"
                parameters = (checkpoint_id,)
            rows = self._connection.execute(
                f"""
                SELECT n.*, c.title AS checkpoint_title,
                    GROUP_CONCAT(DISTINCT substr(e.excerpt, 1, 800)) AS evidence_text
                FROM graph_node n
                JOIN checkpoint c ON c.id = n.checkpoint_id
                LEFT JOIN graph_edge ge
                    ON ge.checkpoint_id = n.checkpoint_id
                   AND (ge.from_node_id = n.id OR ge.to_node_id = n.id)
                LEFT JOIN graph_evidence e ON e.id = ge.evidence_id
                {where}
                GROUP BY n.id
                ORDER BY n.updated_at DESC
                """,
                parameters,
            ).fetchall()
        documents: list[dict] = []
        for row in rows:
            evidence = row["evidence_text"] or ""
            text = "\n".join(
                part
                for part in (
                    row["checkpoint_title"],
                    row["label"],
                    row["searchable_text"],
                    evidence[:2_000],
                )
                if part
            )[:4_000]
            documents.append(
                {
                    "id": f"graph:{row['id']}",
                    "text": text,
                    "metadata": {
                        "checkpoint_id": row["checkpoint_id"],
                        "graph_node_id": row["id"],
                        "kind": row["kind"],
                    },
                }
            )
        return documents

    def ensure_public_subject_node(
        self,
        *,
        checkpoint_id: str,
        canonical_name: str,
        subject_kind: str,
        observation_id: str | None = None,
    ) -> str:
        now = _iso_now()
        canonical_key = hashlib.sha256(
            f"{subject_kind}:{canonical_name.casefold()}".encode("utf-8")
        ).hexdigest()
        with self._lock:
            checkpoint = self._connection.execute(
                "SELECT title FROM checkpoint WHERE id = ?", (checkpoint_id,)
            ).fetchone()
            if checkpoint is None:
                raise KeyError(checkpoint_id)
            episode = self._connection.execute(
                """
                SELECT id FROM graph_node
                WHERE checkpoint_id = ? AND kind = 'episode' AND canonical_key = ?
                """,
                (checkpoint_id, checkpoint_id),
            ).fetchone()
            if episode is None:
                raise RuntimeError("checkpoint episode node is missing")
            existing_private = self._connection.execute(
                """
                SELECT id FROM graph_node
                WHERE checkpoint_id = ? AND kind = 'entity'
                  AND sensitivity = 'private' AND canonical_key = ?
                LIMIT 1
                """,
                (checkpoint_id, f"subject:{canonical_key}"),
            ).fetchone()
            node_id = (
                str(existing_private["id"])
                if existing_private
                else self._upsert_graph_node_locked(
                    checkpoint_id=checkpoint_id,
                    kind="entity",
                    canonical_key=f"public-subject:{canonical_key}",
                    label=canonical_name,
                    searchable_text=canonical_name,
                    sensitivity="public",
                    confidence=1.0,
                    properties={"subject_kind": subject_kind},
                    timestamp=now,
                )
            )
            self._insert_graph_edge_locked(
                checkpoint_id=checkpoint_id,
                observation_id=observation_id,
                from_node_id=episode["id"],
                to_node_id=node_id,
                kind="ABOUT",
                confidence=1.0,
                evidence_id=None,
                observed_at=now,
            )
            self._connection.commit()
        return node_id

    def node_belongs_to_checkpoint(
        self, node_id: str, checkpoint_id: str, *, kind: str | None = None
    ) -> bool:
        with self._lock:
            row = self._connection.execute(
                "SELECT kind FROM graph_node WHERE id = ? AND checkpoint_id = ?",
                (node_id, checkpoint_id),
            ).fetchone()
        return row is not None and (kind is None or row["kind"] == kind)

    def subject_node_matches(
        self,
        node_id: str,
        checkpoint_id: str,
        *,
        canonical_name: str,
        subject_kind: str,
    ) -> bool:
        with self._lock:
            row = self._connection.execute(
                """
                SELECT label, properties_json FROM graph_node
                WHERE id = ? AND checkpoint_id = ? AND kind = 'entity'
                """,
                (node_id, checkpoint_id),
            ).fetchone()
        if (
            row is None
            or " ".join(row["label"].split()).casefold() != canonical_name.casefold()
        ):
            return False
        try:
            properties = json.loads(row["properties_json"] or "{}")
        except (json.JSONDecodeError, TypeError):
            return False
        return (
            isinstance(properties, dict)
            and properties.get("subject_kind") == subject_kind
        )

    def create_enrichment_job(
        self,
        *,
        checkpoint_id: str,
        subject_node_id: str | None,
        public_subject: str,
        public_query: str,
        query_hash: str,
        policy_result: str,
        policy_reason: str,
        status: str,
        ttl_hours: int = 24,
        observation_id: str | None = None,
        expires_at: datetime | None = None,
        network_attempted: bool = False,
    ) -> str:
        job_id = str(uuid4())
        now = datetime.now(timezone.utc)
        with self._lock:
            self._connection.execute(
                """
                INSERT INTO enrichment_job (
                    id, checkpoint_id, observation_id, subject_node_id,
                    public_subject, public_query,
                    query_hash, policy_result, policy_reason, status, result_json,
                    network_attempted, created_at, checked_at, expires_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '[]', ?, ?, ?, ?)
                """,
                (
                    job_id,
                    checkpoint_id,
                    observation_id,
                    subject_node_id,
                    public_subject,
                    public_query,
                    query_hash,
                    policy_result,
                    policy_reason,
                    status,
                    int(network_attempted),
                    now.isoformat(),
                    now.isoformat(),
                    _utc_iso(expires_at)
                    if expires_at is not None
                    else (now + timedelta(hours=ttl_hours)).isoformat(),
                ),
            )
            self._connection.commit()
        return job_id

    def recent_enrichment(self, query_hash: str) -> dict | None:
        """Return any unexpired attempt, not just successful provider results."""

        now = _iso_now()
        with self._lock:
            row = self._connection.execute(
                """
                SELECT * FROM enrichment_job
                WHERE query_hash = ? AND expires_at > ?
                  AND status IN (
                      'running', 'complete', 'cached', 'failed',
                      'provider_unavailable', 'rate_limited'
                  )
                ORDER BY checked_at DESC, id DESC
                LIMIT 1
                """,
                (query_hash, now),
            ).fetchone()
        if row is None:
            return None
        return {
            "job_id": row["id"],
            "status": row["status"],
            "sources": [
                PublicSource.model_validate(item)
                for item in json.loads(row["result_json"] or "[]")
            ],
            "checked_at": datetime.fromisoformat(row["checked_at"]),
            "expires_at": datetime.fromisoformat(row["expires_at"]),
        }

    def network_enrichment_attempts_since(self, cutoff: datetime) -> int:
        with self._lock:
            return int(
                self._connection.execute(
                    """
                    SELECT COUNT(*) AS count FROM enrichment_job
                    WHERE created_at >= ?
                      AND network_attempted = 1
                    """,
                    (_utc_iso(cutoff),),
                ).fetchone()["count"]
            )

    def complete_enrichment_job(
        self,
        job_id: str,
        *,
        status: str,
        sources: list[PublicSource],
        expires_at: datetime | None = None,
    ) -> datetime:
        checked_at = datetime.now(timezone.utc)
        payload = [source.model_dump(mode="json") for source in sources[:2]]
        with self._lock:
            self._connection.execute(
                """
                UPDATE enrichment_job
                SET status = ?, result_json = ?, checked_at = ?,
                    expires_at = COALESCE(?, expires_at)
                WHERE id = ?
                """,
                (
                    status,
                    json.dumps(payload, ensure_ascii=False, separators=(",", ":")),
                    checked_at.isoformat(),
                    _utc_iso(expires_at) if expires_at is not None else None,
                    job_id,
                ),
            )
            self._connection.commit()
        return checked_at

    def cached_enrichment(self, query_hash: str) -> dict | None:
        now = _iso_now()
        with self._lock:
            row = self._connection.execute(
                """
                SELECT * FROM enrichment_job
                WHERE query_hash = ? AND status = 'complete' AND expires_at > ?
                ORDER BY checked_at DESC, id DESC
                LIMIT 1
                """,
                (query_hash, now),
            ).fetchone()
        if row is None:
            return None
        return {
            "job_id": row["id"],
            "sources": [
                PublicSource.model_validate(item)
                for item in json.loads(row["result_json"])
            ],
            "checked_at": datetime.fromisoformat(row["checked_at"]),
        }

    def attach_public_sources(
        self,
        *,
        checkpoint_id: str,
        subject_node_id: str,
        sources: list[PublicSource],
        observation_id: str | None = None,
    ) -> None:
        now = _iso_now()
        with self._lock:
            for source in sources[:2]:
                source_key = hashlib.sha256(source.url.encode("utf-8")).hexdigest()
                source_node = self._upsert_graph_node_locked(
                    checkpoint_id=checkpoint_id,
                    kind="web_source",
                    canonical_key=f"web:{source_key}",
                    label=source.title,
                    searchable_text="\n".join(
                        part for part in (source.title, source.snippet or "") if part
                    ),
                    sensitivity="public",
                    confidence=1.0,
                    properties={"url": source.url},
                    timestamp=now,
                )
                excerpt = (source.snippet or source.title)[:1_000]
                evidence_id = str(uuid4())
                self._connection.execute(
                    """
                    INSERT INTO graph_evidence (
                        id, checkpoint_id, observation_id, source_kind, source_ref,
                        excerpt, evidence_hash, captured_at
                    ) VALUES (?, ?, ?, 'public_web', ?, ?, ?, ?)
                    """,
                    (
                        evidence_id,
                        checkpoint_id,
                        observation_id,
                        source.url,
                        excerpt,
                        hashlib.sha256(excerpt.encode("utf-8")).hexdigest(),
                        now,
                    ),
                )
                self._insert_graph_edge_locked(
                    checkpoint_id=checkpoint_id,
                    observation_id=observation_id,
                    from_node_id=subject_node_id,
                    to_node_id=source_node,
                    kind="SUPPORTED_BY",
                    confidence=1.0,
                    evidence_id=evidence_id,
                    observed_at=now,
                )
            self._connection.commit()

    def public_source_references(
        self, checkpoint_id: str, *, limit: int = 2
    ) -> list[SourceReference]:
        """Return only public-web evidence suitable for a local result card."""

        safe_limit = max(1, min(limit, 2))
        with self._lock:
            rows = self._connection.execute(
                """
                SELECT e.source_ref AS url, e.excerpt, e.captured_at,
                       COALESCE(n.label, e.source_ref) AS title
                FROM graph_evidence e
                LEFT JOIN graph_edge ge ON ge.evidence_id = e.id
                LEFT JOIN graph_node n
                    ON n.id = ge.to_node_id AND n.kind = 'web_source'
                WHERE e.checkpoint_id = ?
                  AND e.source_kind = 'public_web'
                  AND e.source_ref LIKE 'https://%'
                ORDER BY e.captured_at DESC
                """,
                (checkpoint_id,),
            ).fetchall()
        references: list[SourceReference] = []
        seen: set[str] = set()
        for row in rows:
            url = row["url"]
            if not url or url in seen:
                continue
            seen.add(url)
            references.append(
                SourceReference(
                    url=url,
                    title=row["title"],
                    excerpt=row["excerpt"],
                    checked_at=datetime.fromisoformat(row["captured_at"]),
                )
            )
            if len(references) == safe_limit:
                break
        return references

    def erase_recent(self, minutes: int = 15) -> EraseRecentResponse:
        erased_at = datetime.now(timezone.utc)
        since = erased_at - timedelta(minutes=max(1, min(minutes, 60)))
        cutoff = since.isoformat()
        with self._lock:
            affected_checkpoint_ids = [
                row["checkpoint_id"]
                for row in self._connection.execute(
                    """
                    SELECT DISTINCT checkpoint_id
                    FROM observation
                    WHERE captured_at >= ?
                    """,
                    (cutoff,),
                ).fetchall()
            ]
            before = {
                "observations": self._count_locked(
                    "observation", "captured_at >= ?", (cutoff,)
                ),
                "nodes": self._count_locked("graph_node"),
                "edges": self._count_locked(
                    "graph_edge", "observed_at >= ?", (cutoff,)
                ),
                "evidence": self._count_locked(
                    "graph_evidence", "captured_at >= ?", (cutoff,)
                ),
                "enrichment_jobs": self._count_locked(
                    "enrichment_job", "created_at >= ?", (cutoff,)
                ),
                "source_versions": self._count_locked(
                    "source_version", "fetched_at >= ?", (cutoff,)
                ),
            }
            self._connection.execute(
                "DELETE FROM enrichment_job WHERE created_at >= ?", (cutoff,)
            )
            self._connection.execute(
                "DELETE FROM graph_edge WHERE observed_at >= ?", (cutoff,)
            )
            self._connection.execute(
                "DELETE FROM graph_evidence WHERE captured_at >= ?", (cutoff,)
            )
            self._connection.execute(
                "DELETE FROM observation WHERE captured_at >= ?", (cutoff,)
            )
            self._connection.execute(
                "DELETE FROM source_version WHERE fetched_at >= ?", (cutoff,)
            )
            self._connection.execute(
                """
                DELETE FROM graph_node
                WHERE kind != 'episode'
                  AND NOT EXISTS (
                    SELECT 1 FROM graph_edge
                    WHERE from_node_id = graph_node.id OR to_node_id = graph_node.id
                  )
                """
            )
            for checkpoint_id in affected_checkpoint_ids:
                remaining = self._connection.execute(
                    "SELECT COUNT(*) AS count FROM observation WHERE checkpoint_id = ?",
                    (checkpoint_id,),
                ).fetchone()["count"]
                if remaining == 0 and checkpoint_id.startswith("ambient-"):
                    # The ambient episode is derived entirely from observations;
                    # retaining its summary/artifacts would defeat recent erase.
                    self._connection.execute(
                        "DELETE FROM checkpoint WHERE id = ?", (checkpoint_id,)
                    )
                    continue
                self._refresh_private_subject_nodes_locked(checkpoint_id)
                self._refresh_private_artifact_nodes_locked(checkpoint_id)
                if checkpoint_id.startswith("ambient-"):
                    self._refresh_ambient_checkpoint_locked(checkpoint_id)
            nodes_after = self._count_locked("graph_node")
            self._connection.commit()
        return EraseRecentResponse(
            erased_at=erased_at,
            since=since,
            observations=before["observations"],
            nodes=max(0, before["nodes"] - nodes_after),
            edges=before["edges"],
            evidence=before["evidence"],
            enrichment_jobs=before["enrichment_jobs"],
            source_versions=before["source_versions"],
        )

    def save_source_version(
        self,
        *,
        checkpoint_id: str,
        canonical_url: str,
        body_hash: str,
        normalized_text: str,
    ) -> SourceVersion:
        if self.get(checkpoint_id) is None:
            raise KeyError(checkpoint_id)
        source_id = str(uuid4())
        fetched_at = _iso_now()
        with self._lock:
            self._connection.execute(
                """
                UPDATE source_version
                SET is_current = 0
                WHERE checkpoint_id = ? AND canonical_url = ?
                """,
                (checkpoint_id, canonical_url),
            )
            self._connection.execute(
                """
                INSERT INTO source_version (
                    id, checkpoint_id, canonical_url, fetched_at,
                    body_hash, normalized_text, is_current
                ) VALUES (?, ?, ?, ?, ?, ?, 1)
                """,
                (
                    source_id,
                    checkpoint_id,
                    canonical_url,
                    fetched_at,
                    body_hash,
                    normalized_text,
                ),
            )
            self._connection.commit()
        return SourceVersion(
            id=source_id,
            checkpoint_id=checkpoint_id,
            canonical_url=canonical_url,
            fetched_at=fetched_at,
            body_hash=body_hash,
            normalized_text=normalized_text,
            is_current=True,
        )

    def latest_source_version(
        self, checkpoint_id: str, canonical_url: str
    ) -> SourceVersion | None:
        with self._lock:
            row = self._connection.execute(
                """
                SELECT * FROM source_version
                WHERE checkpoint_id = ? AND canonical_url = ?
                ORDER BY fetched_at DESC
                LIMIT 1
                """,
                (checkpoint_id, canonical_url),
            ).fetchone()
        if row is None:
            return None
        return SourceVersion(
            id=row["id"],
            checkpoint_id=row["checkpoint_id"],
            canonical_url=row["canonical_url"],
            fetched_at=row["fetched_at"],
            body_hash=row["body_hash"],
            normalized_text=row["normalized_text"],
            is_current=bool(row["is_current"]),
        )

    def touch_source_version(self, source_version_id: str) -> SourceVersion | None:
        fetched_at = _iso_now()
        with self._lock:
            self._connection.execute(
                "UPDATE source_version SET fetched_at = ? WHERE id = ?",
                (fetched_at, source_version_id),
            )
            self._connection.commit()
            row = self._connection.execute(
                "SELECT * FROM source_version WHERE id = ?", (source_version_id,)
            ).fetchone()
        if row is None:
            return None
        return SourceVersion(
            id=row["id"],
            checkpoint_id=row["checkpoint_id"],
            canonical_url=row["canonical_url"],
            fetched_at=row["fetched_at"],
            body_hash=row["body_hash"],
            normalized_text=row["normalized_text"],
            is_current=bool(row["is_current"]),
        )

    def all_records(self) -> Iterable[CheckpointRecord]:
        with self._lock:
            rows = self._connection.execute(
                """
                SELECT * FROM checkpoint
                WHERE status = 'saved'
                ORDER BY saved_at DESC
                """
            ).fetchall()
        return [self._record(row) for row in rows]

    def _upsert_graph_node_locked(
        self,
        *,
        checkpoint_id: str,
        kind: str,
        canonical_key: str,
        label: str,
        searchable_text: str,
        sensitivity: str,
        confidence: float,
        properties: dict,
        timestamp: str,
    ) -> str:
        existing = self._connection.execute(
            """
            SELECT id, created_at FROM graph_node
            WHERE checkpoint_id = ? AND kind = ? AND canonical_key = ?
            """,
            (checkpoint_id, kind, canonical_key),
        ).fetchone()
        node_id = existing["id"] if existing else str(uuid4())
        created_at = existing["created_at"] if existing else timestamp
        self._connection.execute(
            """
            INSERT INTO graph_node (
                id, checkpoint_id, kind, canonical_key, label, searchable_text,
                sensitivity, confidence, properties_json, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(checkpoint_id, kind, canonical_key) DO UPDATE SET
                label = excluded.label,
                searchable_text = excluded.searchable_text,
                sensitivity = excluded.sensitivity,
                confidence = MAX(graph_node.confidence, excluded.confidence),
                properties_json = excluded.properties_json,
                updated_at = excluded.updated_at
            """,
            (
                node_id,
                checkpoint_id,
                kind,
                canonical_key,
                label[:500],
                searchable_text[:4_000],
                sensitivity,
                confidence,
                json.dumps(properties, ensure_ascii=False, separators=(",", ":")),
                created_at,
                timestamp,
            ),
        )
        return node_id

    def _insert_graph_edge_locked(
        self,
        *,
        checkpoint_id: str,
        observation_id: str | None,
        from_node_id: str,
        to_node_id: str,
        kind: str,
        confidence: float,
        evidence_id: str | None,
        observed_at: str,
    ) -> str:
        if observation_id is None:
            existing = self._connection.execute(
                """
                SELECT id FROM graph_edge
                WHERE checkpoint_id = ? AND observation_id IS NULL
                  AND from_node_id = ? AND to_node_id = ? AND kind = ?
                """,
                (checkpoint_id, from_node_id, to_node_id, kind),
            ).fetchone()
            if existing:
                self._connection.execute(
                    """
                    UPDATE graph_edge
                    SET confidence = MAX(confidence, ?), evidence_id = COALESCE(?, evidence_id),
                        observed_at = ?
                    WHERE id = ?
                    """,
                    (confidence, evidence_id, observed_at, existing["id"]),
                )
                return str(existing["id"])
        edge_id = str(uuid4())
        self._connection.execute(
            """
            INSERT OR IGNORE INTO graph_edge (
                id, checkpoint_id, observation_id, from_node_id, to_node_id,
                kind, confidence, evidence_id, observed_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                edge_id,
                checkpoint_id,
                observation_id,
                from_node_id,
                to_node_id,
                kind,
                confidence,
                evidence_id,
                observed_at,
            ),
        )
        return edge_id

    def _count_locked(
        self, table: str, where: str | None = None, parameters: tuple = ()
    ) -> int:
        allowed = {
            "observation",
            "graph_node",
            "graph_edge",
            "graph_evidence",
            "enrichment_job",
            "source_version",
        }
        if table not in allowed:  # pragma: no cover - internal misuse guard
            raise ValueError("unsupported table")
        statement = f"SELECT COUNT(*) AS count FROM {table}"
        if where:
            statement += f" WHERE {where}"
        return int(self._connection.execute(statement, parameters).fetchone()["count"])

    @staticmethod
    def _graph_node(row: sqlite3.Row) -> GraphNode:
        return GraphNode(
            id=row["id"],
            checkpoint_id=row["checkpoint_id"],
            kind=row["kind"],
            label=row["label"],
            sensitivity=row["sensitivity"],
            confidence=row["confidence"],
            created_at=row["created_at"],
            updated_at=row["updated_at"],
        )

    @staticmethod
    def _graph_edge(row: sqlite3.Row) -> GraphEdge:
        return GraphEdge(
            id=row["id"],
            checkpoint_id=row["checkpoint_id"],
            from_node_id=row["from_node_id"],
            to_node_id=row["to_node_id"],
            kind=row["kind"],
            confidence=row["confidence"],
            evidence_id=row["evidence_id"],
            observed_at=row["observed_at"],
        )

    @staticmethod
    def _graph_evidence(row: sqlite3.Row) -> GraphEvidence:
        return GraphEvidence(
            id=row["id"],
            checkpoint_id=row["checkpoint_id"],
            source_kind=row["source_kind"],
            source_ref=row["source_ref"],
            excerpt=row["excerpt"],
            captured_at=row["captured_at"],
        )

    @staticmethod
    def _record(row: sqlite3.Row) -> CheckpointRecord:
        payload = json.loads(row["payload_json"])
        return CheckpointRecord(
            id=row["id"],
            title=row["title"],
            summary=row["summary"],
            next_step=row["next_step"],
            artifacts=payload.get("artifacts", []),
            status="saved",
            created_at=row["created_at"],
            saved_at=row["saved_at"],
        )
