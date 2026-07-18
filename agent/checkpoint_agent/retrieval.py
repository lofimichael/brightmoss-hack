from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Protocol
from uuid import uuid4

from .repository import CheckpointRepository
from .schemas import CheckpointRecord


@dataclass(frozen=True)
class SearchHit:
    checkpoint_id: str
    score: float
    provider: str


class SearchIndex(Protocol):
    name: str
    available: bool

    async def rebuild(self, records: list[CheckpointRecord]) -> None: ...

    async def upsert(self, record: CheckpointRecord) -> None: ...

    async def delete(self, checkpoint_id: str) -> None: ...

    async def search(self, query: str, limit: int) -> list[SearchHit]: ...


class UnavailableSearchIndex:
    name = "sqlite-substring"
    available = False

    def __init__(self, reason: str = "Moss session not enabled") -> None:
        self.reason = reason

    async def rebuild(self, records: list[CheckpointRecord]) -> None:
        return None

    async def upsert(self, record: CheckpointRecord) -> None:
        return None

    async def delete(self, checkpoint_id: str) -> None:
        return None

    async def search(self, query: str, limit: int) -> list[SearchHit]:
        return []

    async def upsert_graph_documents(self, documents: list[dict]) -> None:
        return None

    async def delete_graph_documents(self, document_ids: list[str]) -> None:
        return None


class MossSessionSearchIndex:
    """Adapter for a verified Moss SessionIndex; it never calls push_index()."""

    name = "moss-session-local"
    available = True

    def __init__(
        self, session: object, document_type: type, query_options_type: type
    ) -> None:
        self._session = session
        self._document_type = document_type
        self._query_options_type = query_options_type
        self.last_error: str | None = None

    @classmethod
    async def from_environment(cls) -> SearchIndex:
        configured = os.getenv("CHECKPOINT_ENABLE_MOSS_SESSION")
        if configured is not None and configured.strip().casefold() in {
            "0",
            "false",
            "no",
            "off",
        }:
            return UnavailableSearchIndex("Moss explicitly disabled")
        project_id = (os.getenv("MOSS_PROJECT_ID") or "").strip()
        project_key = (os.getenv("MOSS_PROJECT_KEY") or "").strip()
        if not project_id or not project_key:
            return UnavailableSearchIndex("Moss credentials missing")
        return await cls.from_credentials(project_id, project_key)

    @classmethod
    async def from_credentials(cls, project_id: str, project_key: str) -> SearchIndex:
        try:
            os.environ.setdefault("MOSS_DISABLE_TELEMETRY", "1")
            from moss import DocumentInfo, MossClient, QueryOptions

            client = MossClient(project_id, project_key)
            # A unique name guarantees this process does not hydrate a pre-existing
            # cloud corpus. SQLite is rebuilt into a fresh in-memory session below.
            session = await client.session(
                index_name=f"checkpoint-local-{uuid4()}",
                model_id=os.getenv("MOSS_MODEL_ID", "moss-minilm"),
            )
            return cls(session, DocumentInfo, QueryOptions)
        except Exception as error:  # optional provider must never break local search
            return UnavailableSearchIndex(f"Moss unavailable: {type(error).__name__}")

    @staticmethod
    def _text(record: CheckpointRecord) -> str:
        artifacts = "\n".join(
            part
            for artifact in record.artifacts
            for part in (
                artifact.display_name,
                artifact.resource or "",
                artifact.captured_text or "",
            )
            if part
        )
        return "\n".join(
            part
            for part in (
                record.title,
                record.summary,
                record.next_step or "",
                artifacts,
            )
            if part
        )

    async def rebuild(self, records: list[CheckpointRecord]) -> None:
        try:
            existing = await self._session.get_docs()
            existing_ids = [document.id for document in existing]
            if existing_ids:
                await self._session.delete_docs(existing_ids)
            if records:
                await self._session.add_docs(
                    [
                        self._document_type(
                            id=f"checkpoint:{record.id}",
                            text=self._text(record),
                            metadata={"checkpoint_id": record.id},
                        )
                        for record in records
                    ]
                )
        except Exception as error:
            self.available = False
            self.last_error = type(error).__name__

    async def upsert(self, record: CheckpointRecord) -> None:
        if not self.available:
            return
        try:
            await self._session.add_docs(
                [
                    self._document_type(
                        id=f"checkpoint:{record.id}",
                        text=self._text(record),
                        metadata={"checkpoint_id": record.id},
                    )
                ]
            )
        except Exception as error:
            self.available = False
            self.last_error = type(error).__name__

    async def delete(self, checkpoint_id: str) -> None:
        if not self.available:
            return
        try:
            await self._session.delete_docs([f"checkpoint:{checkpoint_id}"])
        except Exception as error:
            self.available = False
            self.last_error = type(error).__name__

    async def search(self, query: str, limit: int) -> list[SearchHit]:
        if not self.available:
            return []
        try:
            result = await self._session.query(
                query, self._query_options_type(top_k=max(1, min(limit, 20)))
            )
            hits: list[SearchHit] = []
            for document in result.docs:
                checkpoint_id = getattr(document, "metadata", {}).get("checkpoint_id")
                if not checkpoint_id and str(document.id).startswith("checkpoint:"):
                    checkpoint_id = str(document.id).split(":", 1)[1]
                if checkpoint_id:
                    hits.append(
                        SearchHit(
                            checkpoint_id=str(checkpoint_id),
                            score=float(document.score),
                            provider="moss",
                        )
                    )
            return hits
        except Exception as error:
            self.available = False
            self.last_error = type(error).__name__
            return []

    async def upsert_graph_documents(self, documents: list[dict]) -> None:
        if not self.available or not documents:
            return
        try:
            await self._session.add_docs(
                [
                    self._document_type(
                        id=document["id"],
                        text=document["text"],
                        metadata=document["metadata"],
                    )
                    for document in documents
                ]
            )
        except Exception as error:
            self.available = False
            self.last_error = type(error).__name__

    async def delete_graph_documents(self, document_ids: list[str]) -> None:
        if not self.available or not document_ids:
            return
        try:
            await self._session.delete_docs(document_ids)
        except Exception as error:
            self.available = False
            self.last_error = type(error).__name__


class CheckpointRetriever:
    def __init__(self, repository: CheckpointRepository, index: SearchIndex) -> None:
        self.repository = repository
        self.index = index

    async def search(
        self, query: str, limit: int = 5
    ) -> list[tuple[CheckpointRecord, float, str]]:
        semantic = await self.index.search(query, limit)
        literal = self.repository.search(query, limit)
        merged: dict[str, tuple[CheckpointRecord, float, str]] = {}
        for hit in semantic:
            record = self.repository.get(hit.checkpoint_id)
            if record is not None:
                # Semantic scores are typically 0..1; keep them ahead of weak
                # fallback hits without pretending score scales are identical.
                score = 1_000.0 + hit.score
                existing = merged.get(record.id)
                if existing is None or score > existing[1]:
                    merged[record.id] = (record, score, hit.provider)
        for record, score in literal:
            existing = merged.get(record.id)
            if existing is None:
                merged[record.id] = (record, score, "sqlite")
        return sorted(merged.values(), key=lambda item: item[1], reverse=True)[:limit]
