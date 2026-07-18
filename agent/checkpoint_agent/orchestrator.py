from __future__ import annotations

import re
from dataclasses import dataclass
from threading import RLock
from uuid import uuid4

from .freshness import (
    FreshnessError,
    ProviderUnavailable,
    SavedURLFreshnessService,
    cached_source_reference,
)
from .planner import DeterministicPlanner, Planner
from .repository import CheckpointRepository
from .retrieval import CheckpointRetriever, SearchIndex
from .schemas import (
    CheckpointCreate,
    CheckpointRecord,
    OutcomeKind,
    ProposalDecision,
    ProposedAction,
    TurnResponse,
    UserTurn,
)


_RESTORE_WORDS = re.compile(r"\b(resume|restore|reopen|open|pick up|continue)\b", re.I)
_REFRESH_WORDS = re.compile(
    r"\b(refresh|fresh|current|latest|changed|up[ -]to[ -]date)\b", re.I
)


@dataclass
class _Proposal:
    proposal_id: str
    actions: list[ProposedAction]
    status: str = "pending"


class ProposalStore:
    def __init__(self) -> None:
        self._lock = RLock()
        self._proposals: dict[str, _Proposal] = {}

    def create(self, actions: list[ProposedAction]) -> _Proposal:
        proposal = _Proposal(proposal_id=str(uuid4()), actions=list(actions))
        with self._lock:
            self._proposals[proposal.proposal_id] = proposal
        return proposal

    def decide(self, proposal_id: str, decision: ProposalDecision) -> TurnResponse:
        with self._lock:
            proposal = self._proposals.get(proposal_id)
            if proposal is None:
                raise KeyError(proposal_id)
            if proposal.status != "pending":
                raise ValueError("proposal has already been decided")
            if decision == ProposalDecision.APPROVE:
                proposal.status = "approved"
                return TurnResponse(
                    request_id=str(uuid4()),
                    kind=OutcomeKind.RESULT_CARD,
                    proposal_id=proposal_id,
                    status="approved",
                    message="Approved. The Mac app must validate and execute these exact targets.",
                    proposed_actions=list(proposal.actions),
                    provider_disclosure=["Local memory"],
                )
            proposal.status = "cancelled"
            return TurnResponse(
                request_id=str(uuid4()),
                kind=OutcomeKind.RESULT_CARD,
                proposal_id=proposal_id,
                status="cancelled",
                message="Cancelled. Nothing was opened.",
                proposed_actions=[],
                provider_disclosure=["Local memory"],
            )


class RequestOrchestrator:
    def __init__(
        self,
        repository: CheckpointRepository,
        index: SearchIndex,
        freshness: SavedURLFreshnessService,
        planner: Planner | None = None,
        proposals: ProposalStore | None = None,
    ) -> None:
        self.repository = repository
        self.index = index
        self.retriever = CheckpointRetriever(repository, index)
        self.freshness = freshness
        self.planner = planner or DeterministicPlanner()
        self.proposals = proposals or ProposalStore()

    async def rebuild_index(self) -> None:
        await self.index.rebuild(list(self.repository.all_records()))
        upsert_graph = getattr(self.index, "upsert_graph_documents", None)
        if upsert_graph is not None:
            await upsert_graph(self.repository.graph_documents())

    async def save_checkpoint(self, draft: CheckpointCreate) -> CheckpointRecord:
        record = self.repository.save(draft)
        await self.index.upsert(record)
        upsert_graph = getattr(self.index, "upsert_graph_documents", None)
        if upsert_graph is not None:
            await upsert_graph(self.repository.graph_documents(record.id))
        return record

    async def delete_checkpoint(self, checkpoint_id: str) -> bool:
        graph_document_ids = [
            document["id"]
            for document in self.repository.graph_documents(checkpoint_id)
        ]
        deleted = self.repository.delete(checkpoint_id)
        if deleted:
            await self.index.delete(checkpoint_id)
            delete_graph = getattr(self.index, "delete_graph_documents", None)
            if delete_graph is not None:
                await delete_graph(graph_document_ids)
        return deleted

    async def handle_turn(self, turn: UserTurn) -> TurnResponse:
        request_id = turn.request_id or str(uuid4())
        if _REFRESH_WORDS.search(turn.text):
            return await self._handle_refresh(request_id, turn)

        matches = await self.retriever.search(turn.text, limit=5)
        if matches:
            checkpoint, _, provider = matches[0]
            disclosures = ["Moss · local"] if provider == "moss" else ["Local memory"]
            sources = self.repository.public_source_references(checkpoint.id, limit=2)
            if sources:
                disclosures.append("Bright Data · public context")
            actions = self._restore_actions(checkpoint)
            if _RESTORE_WORDS.search(turn.text) and actions:
                proposal = self.proposals.create(actions)
                return TurnResponse(
                    request_id=request_id,
                    kind=OutcomeKind.CONFIRMATION_CARD,
                    message=f"Ready to reopen {checkpoint.title}. Review these items first.",
                    checkpoint=checkpoint,
                    sources=sources,
                    proposed_actions=actions,
                    proposal_id=proposal.proposal_id,
                    provider_disclosure=disclosures,
                )
            return TurnResponse(
                request_id=request_id,
                kind=OutcomeKind.RESULT_CARD,
                message=(
                    "Most recently, "
                    + checkpoint.summary[:1].lower()
                    + checkpoint.summary[1:].rstrip(".")
                    + "."
                    if checkpoint.id.startswith("ambient-")
                    else f"I found {checkpoint.title} in your local checkpoints."
                ),
                checkpoint=checkpoint,
                sources=sources,
                provider_disclosure=disclosures,
            )

        try:
            message = await self.planner.answer(turn, [])
            disclosure = (
                ["OpenAI · cloud AI"]
                if self.planner.name == "openai"
                else ["Local memory"]
            )
        except Exception:
            message = await DeterministicPlanner().answer(turn, [])
            disclosure = ["Local memory"]
        return TurnResponse(
            request_id=request_id,
            kind=OutcomeKind.MESSAGE,
            message=message,
            provider_disclosure=disclosure,
        )

    async def _handle_refresh(self, request_id: str, turn: UserTurn) -> TurnResponse:
        checkpoint = (
            self.repository.get(turn.checkpoint_id) if turn.checkpoint_id else None
        )
        if checkpoint is None:
            matches = await self.retriever.search(turn.text, limit=1)
            checkpoint = matches[0][0] if matches else self._only_recent_with_url()
        if checkpoint is None:
            return TurnResponse(
                request_id=request_id,
                kind=OutcomeKind.MESSAGE,
                message="Choose a checkpoint with a saved public page before refreshing.",
                provider_disclosure=["Local memory"],
            )
        url = turn.url or self._first_saved_url(checkpoint)
        if not url:
            return TurnResponse(
                request_id=request_id,
                kind=OutcomeKind.RESULT_CARD,
                message="That checkpoint does not contain a saved public page.",
                checkpoint=checkpoint,
                provider_disclosure=["Local memory"],
            )
        if not turn.allow_public_enrichment:
            cached = cached_source_reference(checkpoint)
            return TurnResponse(
                request_id=request_id,
                kind=OutcomeKind.RESULT_CARD,
                message="Public enrichment is off. Showing the saved copy instead.",
                checkpoint=checkpoint,
                sources=[cached] if cached else [],
                provider_disclosure=["Local memory"],
            )
        try:
            result = await self.freshness.refresh(checkpoint, url)
            return TurnResponse(
                request_id=request_id,
                kind=OutcomeKind.RESULT_CARD,
                message=result.message,
                checkpoint=checkpoint,
                sources=[result.source],
                provider_disclosure=["Bright Data · live web"],
            )
        except Exception as error:
            cached = cached_source_reference(checkpoint)
            if isinstance(error, ProviderUnavailable):
                detail = "Live web is not configured. Showing the saved copy instead."
            elif isinstance(error, FreshnessError):
                detail = f"Couldn't refresh: {error}. Showing the saved copy instead."
            else:
                detail = "Live web is unavailable. Showing the saved copy instead."
            return TurnResponse(
                request_id=request_id,
                kind=OutcomeKind.RESULT_CARD,
                message=detail,
                checkpoint=checkpoint,
                sources=[cached] if cached else [],
                provider_disclosure=["Local memory"],
            )

    def _only_recent_with_url(self) -> CheckpointRecord | None:
        candidates = [
            checkpoint
            for checkpoint in self.repository.list_recent(limit=20)
            if self._first_saved_url(checkpoint)
        ]
        return candidates[0] if len(candidates) == 1 else None

    @staticmethod
    def _first_saved_url(checkpoint: CheckpointRecord) -> str | None:
        return next(
            (
                artifact.resource
                for artifact in checkpoint.artifacts
                if artifact.kind == "url" and artifact.resource
            ),
            None,
        )

    @staticmethod
    def _restore_actions(checkpoint: CheckpointRecord) -> list[ProposedAction]:
        actions: list[ProposedAction] = []
        for artifact in checkpoint.artifacts:
            if artifact.kind == "app" and artifact.bundle_id:
                actions.append(
                    ProposedAction(
                        kind="activateApp",
                        display_name=artifact.display_name,
                        bundle_id=artifact.bundle_id,
                    )
                )
            elif artifact.kind == "file" and artifact.resource:
                actions.append(
                    ProposedAction(
                        kind="openFile",
                        display_name=artifact.display_name,
                        resource=artifact.resource,
                    )
                )
            elif (
                artifact.kind == "url"
                and artifact.resource
                and artifact.resource.startswith("https://")
            ):
                actions.append(
                    ProposedAction(
                        kind="openURL",
                        display_name=artifact.display_name,
                        resource=artifact.resource,
                    )
                )
            if len(actions) == 3:
                break
        return actions
