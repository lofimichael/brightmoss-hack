from __future__ import annotations

import asyncio
import json
import os
import secrets
from contextlib import asynccontextmanager
from dataclasses import dataclass
from datetime import datetime

import uvicorn
from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request, status
from pydantic import ValidationError

from .config import Settings
from .enrichment import (
    BrightDataRemoteMCPAdapter,
    KnowledgeGraphService,
    PublicEnricher,
    UnavailablePublicEnricher,
    bright_data_fetcher_from_environment,
)
from .freshness import (
    SavedURLFetcher,
    SavedURLFreshnessService,
    UnavailableSavedURLFetcher,
)
from .orchestrator import RequestOrchestrator
from .planner import DeterministicPlanner, OpenAIPlanner, Planner
from .repository import CheckpointRepository
from .retrieval import MossSessionSearchIndex, SearchIndex, UnavailableSearchIndex
from .schemas import (
    CheckpointCreate,
    CheckpointRecord,
    EnrichmentRequest,
    EnrichmentResponse,
    EraseRecentRequest,
    EraseRecentResponse,
    GraphNeighborhood,
    HealthResponse,
    MemoryDeleteResponse,
    MemoryEnrichmentsResponse,
    MemoryItemsResponse,
    MemoryStats,
    MemorySubjectsResponse,
    ObservationCreate,
    ObservationRecord,
    ProposalDecisionRequest,
    ProviderCapabilityStatus,
    ProviderConfigurationRequest,
    TurnResponse,
    UserTurn,
)


MAX_PROVIDER_CONFIGURATION_BYTES = 24_000


@dataclass(repr=False)
class _ProviderMemory:
    bright_data_api_key: str | None = None
    moss_project_id: str | None = None
    moss_project_key: str | None = None
    openai_api_key: str | None = None
    livekit_url: str | None = None
    livekit_api_key: str | None = None
    livekit_api_secret: str | None = None
    livekit_sandbox_id: str | None = None
    livekit_agent_name: str | None = None

    def __repr__(self) -> str:
        return "_ProviderMemory(<redacted>)"

    @classmethod
    def from_environment(cls) -> "_ProviderMemory":
        return cls(
            bright_data_api_key=os.getenv("BRIGHT_DATA_API_KEY") or None,
            moss_project_id=os.getenv("MOSS_PROJECT_ID") or None,
            moss_project_key=os.getenv("MOSS_PROJECT_KEY") or None,
            openai_api_key=os.getenv("OPENAI_API_KEY") or None,
            livekit_url=os.getenv("LIVEKIT_URL") or None,
            livekit_api_key=os.getenv("LIVEKIT_API_KEY") or None,
            livekit_api_secret=os.getenv("LIVEKIT_API_SECRET") or None,
            livekit_sandbox_id=os.getenv("LIVEKIT_SANDBOX_ID") or None,
            livekit_agent_name=os.getenv("LIVEKIT_AGENT_NAME") or None,
        )

    def merge(self, request: ProviderConfigurationRequest) -> None:
        if "moss_credential" in request.model_fields_set:
            if request.moss_credential is None:
                self.moss_project_id = None
                self.moss_project_key = None
            else:
                project_id, project_key = _parse_moss_credential_bundle(
                    request.moss_credential.get_secret_value()
                )
                self.moss_project_id = project_id
                self.moss_project_key = project_key
        secret_fields = {
            "bright_data_api_key",
            "moss_project_id",
            "moss_project_key",
            "openai_api_key",
            "livekit_url",
            "livekit_api_key",
            "livekit_api_secret",
            "livekit_sandbox_id",
        }
        for field_name in request.model_fields_set:
            if field_name == "moss_credential":
                continue
            value = getattr(request, field_name)
            if value is not None and field_name in secret_fields:
                value = value.get_secret_value()
            # Explicit JSON null is a deletion. The Mac app sends its complete
            # Keychain snapshot after startup and after every edit, so skipping
            # null here would leave removed secrets active in process memory.
            setattr(self, field_name, value)


@dataclass(repr=False)
class _Runtime:
    repository: CheckpointRepository
    orchestrator: RequestOrchestrator
    graph: KnowledgeGraphService
    provider_memory: _ProviderMemory
    bearer_token: str | None
    initialize_moss: bool
    connection_file: str | None

    def __repr__(self) -> str:
        return "_Runtime(<local providers redacted>)"


_UNSET = object()


def _parse_moss_credential_bundle(raw: str) -> tuple[str, str]:
    """Parse our one-field onboarding bundle without accepting a raw key alone."""

    try:
        payload = json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        raise ValueError("invalid Moss credential bundle") from None
    if not isinstance(payload, dict):
        raise ValueError("invalid Moss credential bundle")
    supplied_keys = set(payload)
    if supplied_keys == {"project_id", "project_key"}:
        project_id, project_key = payload["project_id"], payload["project_key"]
    elif supplied_keys == {"MOSS_PROJECT_ID", "MOSS_PROJECT_KEY"}:
        project_id = payload["MOSS_PROJECT_ID"]
        project_key = payload["MOSS_PROJECT_KEY"]
    else:
        raise ValueError("invalid Moss credential bundle")
    if (
        not isinstance(project_id, str)
        or not isinstance(project_key, str)
        or not project_id.strip()
        or not project_key.strip()
        or len(project_id) > 1_024
        or len(project_key) > 4_096
    ):
        raise ValueError("invalid Moss credential bundle")
    return project_id.strip(), project_key.strip()


def _publish_connection(path: str, port: int, token: str) -> None:
    destination = os.path.expanduser(path)
    os.makedirs(os.path.dirname(destination), mode=0o700, exist_ok=True)
    os.chmod(os.path.dirname(destination), 0o700)
    temporary = f"{destination}.{os.getpid()}.tmp"
    payload = json.dumps(
        {"base_url": f"http://127.0.0.1:{port}", "port": port, "token": token},
        separators=(",", ":"),
    ).encode("utf-8")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(descriptor, payload)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    os.chmod(temporary, 0o600)
    os.replace(temporary, destination)


def _remove_own_connection(path: str, token: str) -> None:
    try:
        with open(path, encoding="utf-8") as connection_file:
            current = json.load(connection_file)
        if current.get("token") == token:
            os.unlink(path)
    except (FileNotFoundError, OSError, ValueError, TypeError):
        return


def _provider_capabilities(runtime: _Runtime) -> ProviderCapabilityStatus:
    enricher_name = runtime.graph.enricher.name
    freshness_name = runtime.orchestrator.freshness.fetcher.name
    bright_ready = (
        runtime.graph.enricher.available or runtime.orchestrator.freshness.available
    )
    if (
        enricher_name == "bright-data-remote-mcp"
        or freshness_name == "bright-data-remote-mcp"
    ):
        bright_mode = "remote_mcp"
    elif freshness_name == "bright-data-web-unlocker":
        bright_mode = "web_unlocker"
    else:
        bright_mode = "none"
    moss_configured = bool(
        runtime.provider_memory.moss_project_id
        and runtime.provider_memory.moss_project_key
    )
    if runtime.orchestrator.index.available:
        moss_status = "ready"
    elif moss_configured:
        moss_status = "unavailable"
    else:
        moss_status = "not_configured"
    memory = runtime.provider_memory
    voice_configured = bool(
        memory.livekit_url and memory.livekit_api_key and memory.livekit_api_secret
    )
    return ProviderCapabilityStatus(
        bright_data=(
            "ready"
            if bright_ready
            else "unavailable"
            if memory.bright_data_api_key
            else "not_configured"
        ),
        bright_data_mode=bright_mode,
        moss=moss_status,
        planner="openai" if runtime.orchestrator.planner.name == "openai" else "local",
        voice="restart_required" if voice_configured else "not_configured",
    )


async def _configure_providers(
    runtime: _Runtime, request: ProviderConfigurationRequest
) -> ProviderCapabilityStatus:
    changed = request.model_fields_set
    runtime.provider_memory.merge(request)
    memory = runtime.provider_memory

    if "bright_data_api_key" in changed:
        if memory.bright_data_api_key:
            adapter: PublicEnricher = BrightDataRemoteMCPAdapter(
                memory.bright_data_api_key
            )
            fetcher: SavedURLFetcher = adapter
        else:
            adapter = UnavailablePublicEnricher()
            fetcher = UnavailableSavedURLFetcher()
        runtime.graph.enricher = adapter
        runtime.orchestrator.freshness = SavedURLFreshnessService(
            runtime.repository, fetcher
        )

    if "openai_api_key" in changed:
        runtime.orchestrator.planner = (
            OpenAIPlanner.from_api_key(memory.openai_api_key)
            if memory.openai_api_key
            else DeterministicPlanner()
        )

    if {"moss_project_id", "moss_project_key", "moss_credential"}.intersection(changed):
        if memory.moss_project_id and memory.moss_project_key:
            try:
                active_index = await asyncio.wait_for(
                    MossSessionSearchIndex.from_credentials(
                        memory.moss_project_id, memory.moss_project_key
                    ),
                    timeout=10.0,
                )
            except TimeoutError:
                active_index = UnavailableSearchIndex("Moss configuration timed out")
        else:
            # Local SQLite retrieval remains authoritative after Moss is
            # disconnected; no stale in-process semantic session survives.
            memory.moss_project_id = None
            memory.moss_project_key = None
            active_index = UnavailableSearchIndex("Moss not configured")
        runtime.orchestrator = RequestOrchestrator(
            runtime.repository,
            active_index,
            runtime.orchestrator.freshness,
            planner=runtime.orchestrator.planner,
            proposals=runtime.orchestrator.proposals,
        )
        runtime.graph.index = active_index
        await runtime.orchestrator.rebuild_index()

    return _provider_capabilities(runtime)


def create_app(
    *,
    database_path: str | None = None,
    index: SearchIndex | None = None,
    planner: Planner | None = None,
    fetcher: SavedURLFetcher | None = None,
    enricher: PublicEnricher | None = None,
    bearer_token: str | None | object = _UNSET,
) -> FastAPI:
    settings = Settings.from_environment()
    repository = CheckpointRepository(database_path or settings.database_path)
    initial_index = index or UnavailableSearchIndex("initializing")
    active_planner = planner or OpenAIPlanner.from_environment()
    active_fetcher = fetcher or bright_data_fetcher_from_environment()
    active_enricher = enricher or BrightDataRemoteMCPAdapter.from_environment()
    freshness = SavedURLFreshnessService(repository, active_fetcher)
    resolved_token = (
        settings.bearer_token or secrets.token_urlsafe(32)
        if bearer_token is _UNSET
        else bearer_token
    )
    publish_connection = database_path is None and isinstance(resolved_token, str)
    connection_file = (
        str(settings.data_dir / "agent-connection.json") if publish_connection else None
    )
    orchestrator = RequestOrchestrator(
        repository, initial_index, freshness, planner=active_planner
    )
    runtime = _Runtime(
        repository=repository,
        orchestrator=orchestrator,
        graph=KnowledgeGraphService(repository, initial_index, active_enricher),
        provider_memory=_ProviderMemory.from_environment(),
        bearer_token=resolved_token if isinstance(resolved_token, str) else None,
        initialize_moss=index is None,
        connection_file=connection_file,
    )

    @asynccontextmanager
    async def lifespan(application: FastAPI):
        if runtime.initialize_moss:
            try:
                active_index = await asyncio.wait_for(
                    MossSessionSearchIndex.from_environment(), timeout=10.0
                )
            except TimeoutError:
                active_index = UnavailableSearchIndex("Moss initialization timed out")
            runtime.orchestrator = RequestOrchestrator(
                repository,
                active_index,
                freshness,
                planner=active_planner,
                proposals=runtime.orchestrator.proposals,
            )
            runtime.graph.index = active_index
        await runtime.orchestrator.rebuild_index()
        if runtime.connection_file and runtime.bearer_token:
            _publish_connection(
                runtime.connection_file, settings.port, runtime.bearer_token
            )
        yield
        if runtime.connection_file and runtime.bearer_token:
            _remove_own_connection(runtime.connection_file, runtime.bearer_token)
        repository.close()

    application = FastAPI(
        title="CHECKPOINT local helper",
        version="0.1.0",
        docs_url=None,
        redoc_url=None,
        lifespan=lifespan,
    )
    application.state.runtime = runtime

    async def authorize(authorization: str | None = Header(default=None)) -> None:
        expected = runtime.bearer_token
        if expected is None:
            return
        scheme, _, supplied = (authorization or "").partition(" ")
        if scheme.casefold() != "bearer" or not secrets.compare_digest(
            supplied, expected
        ):
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED, detail="unauthorized"
            )

    @application.get(
        "/health", response_model=HealthResponse, dependencies=[Depends(authorize)]
    )
    async def health() -> HealthResponse:
        orchestrator = runtime.orchestrator
        return HealthResponse(
            search=orchestrator.index.name,
            planner=orchestrator.planner.name,
            freshness=orchestrator.freshness.fetcher.name,
        )

    @application.get(
        "/providers",
        response_model=ProviderCapabilityStatus,
        dependencies=[Depends(authorize)],
    )
    async def provider_status() -> ProviderCapabilityStatus:
        return _provider_capabilities(runtime)

    @application.post(
        "/providers/configure",
        response_model=ProviderCapabilityStatus,
        dependencies=[Depends(authorize)],
    )
    async def configure_providers(request: Request) -> ProviderCapabilityStatus:
        content_length = request.headers.get("content-length")
        try:
            declared_length = int(content_length) if content_length else 0
        except ValueError:
            declared_length = MAX_PROVIDER_CONFIGURATION_BYTES + 1
        if declared_length > MAX_PROVIDER_CONFIGURATION_BYTES:
            raise HTTPException(
                status_code=status.HTTP_413_CONTENT_TOO_LARGE,
                detail="provider configuration is too large",
            )
        body = bytearray()
        async for chunk in request.stream():
            body.extend(chunk)
            if len(body) > MAX_PROVIDER_CONFIGURATION_BYTES:
                raise HTTPException(
                    status_code=status.HTTP_413_CONTENT_TOO_LARGE,
                    detail="provider configuration is too large",
                )
        try:
            payload = json.loads(bytes(body))
            configuration = ProviderConfigurationRequest.model_validate(payload)
        except (UnicodeDecodeError, json.JSONDecodeError, ValidationError, TypeError):
            # FastAPI's normal 422 response can include the invalid input. This
            # write-only route intentionally returns no field values at all.
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                detail="invalid provider configuration",
            ) from None
        try:
            return await _configure_providers(runtime, configuration)
        except ValueError:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                detail="invalid provider configuration",
            ) from None

    @application.post(
        "/turn", response_model=TurnResponse, dependencies=[Depends(authorize)]
    )
    async def turn(request: UserTurn) -> TurnResponse:
        return await runtime.orchestrator.handle_turn(request)

    @application.post(
        "/observations",
        response_model=ObservationRecord,
        status_code=status.HTTP_201_CREATED,
        dependencies=[Depends(authorize)],
    )
    async def save_observation(request: ObservationCreate) -> ObservationRecord:
        try:
            return await runtime.graph.save_observation(request)
        except KeyError as error:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND, detail="checkpoint not found"
            ) from error

    @application.get(
        "/memory/items",
        response_model=MemoryItemsResponse,
        dependencies=[Depends(authorize)],
    )
    async def memory_items(
        limit: int = Query(default=50, ge=1, le=100),
        before: datetime | None = Query(default=None),
        before_id: str | None = Query(default=None),
    ) -> MemoryItemsResponse:
        items, total = runtime.repository.list_memory_items(
            limit=limit, before=before, before_id=before_id
        )
        return MemoryItemsResponse(items=items, total=total)

    @application.get(
        "/memory/enrichments",
        response_model=MemoryEnrichmentsResponse,
        dependencies=[Depends(authorize)],
    )
    async def memory_enrichments(
        limit: int = Query(default=50, ge=1, le=100),
        before: datetime | None = Query(default=None),
        before_id: str | None = Query(default=None),
    ) -> MemoryEnrichmentsResponse:
        items, total = runtime.repository.list_memory_enrichments(
            limit=limit, before=before, before_id=before_id
        )
        return MemoryEnrichmentsResponse(items=items, total=total)

    @application.get(
        "/memory/subjects",
        response_model=MemorySubjectsResponse,
        dependencies=[Depends(authorize)],
    )
    async def memory_subjects(
        limit: int = Query(default=50, ge=1, le=100),
    ) -> MemorySubjectsResponse:
        subjects, total = runtime.repository.memory_subjects(limit=limit)
        return MemorySubjectsResponse(subjects=subjects, total=total)

    @application.get(
        "/memory/stats",
        response_model=MemoryStats,
        dependencies=[Depends(authorize)],
    )
    async def memory_stats() -> MemoryStats:
        return runtime.repository.memory_stats()

    @application.delete(
        "/memory/items/{observation_id}",
        response_model=MemoryDeleteResponse,
        dependencies=[Depends(authorize)],
    )
    async def delete_memory_item(observation_id: str) -> MemoryDeleteResponse:
        deleted, checkpoint_deleted = await runtime.graph.delete_memory_item(
            observation_id
        )
        if not deleted:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND, detail="memory item not found"
            )
        return MemoryDeleteResponse(
            observation_id=observation_id,
            deleted=True,
            checkpoint_deleted=checkpoint_deleted,
        )

    @application.post(
        "/enrichments",
        response_model=EnrichmentResponse,
        dependencies=[Depends(authorize)],
    )
    async def enrich(request: EnrichmentRequest) -> EnrichmentResponse:
        try:
            return await runtime.graph.enrich(request)
        except KeyError as error:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND, detail="checkpoint not found"
            ) from error
        except ValueError as error:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="invalid graph subject",
            ) from error

    @application.get(
        "/graph/checkpoints/{checkpoint_id}",
        response_model=GraphNeighborhood,
        dependencies=[Depends(authorize)],
    )
    async def graph_neighborhood(checkpoint_id: str) -> GraphNeighborhood:
        neighborhood = runtime.repository.graph_neighborhood(checkpoint_id)
        if neighborhood is None:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND, detail="checkpoint not found"
            )
        return neighborhood

    @application.post(
        "/memory/erase-recent",
        response_model=EraseRecentResponse,
        dependencies=[Depends(authorize)],
    )
    async def erase_recent(request: EraseRecentRequest) -> EraseRecentResponse:
        return await runtime.graph.erase_recent(request.minutes)

    @application.post(
        "/checkpoints",
        response_model=CheckpointRecord,
        status_code=status.HTTP_201_CREATED,
        dependencies=[Depends(authorize)],
    )
    async def save_checkpoint(request: CheckpointCreate) -> CheckpointRecord:
        return await runtime.orchestrator.save_checkpoint(request)

    @application.get(
        "/checkpoints",
        response_model=list[CheckpointRecord],
        dependencies=[Depends(authorize)],
    )
    async def recent_checkpoints(
        limit: int = Query(default=20, ge=1, le=100),
    ) -> list[CheckpointRecord]:
        return runtime.repository.list_recent(limit)

    @application.get(
        "/checkpoints/{checkpoint_id}",
        response_model=CheckpointRecord,
        dependencies=[Depends(authorize)],
    )
    async def get_checkpoint(checkpoint_id: str) -> CheckpointRecord:
        checkpoint = runtime.repository.get(checkpoint_id)
        if checkpoint is None:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND, detail="not found"
            )
        return checkpoint

    @application.delete(
        "/checkpoints/{checkpoint_id}",
        status_code=status.HTTP_204_NO_CONTENT,
        dependencies=[Depends(authorize)],
    )
    async def delete_checkpoint(checkpoint_id: str) -> None:
        if not await runtime.orchestrator.delete_checkpoint(checkpoint_id):
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND, detail="not found"
            )

    @application.post(
        "/proposals/{proposal_id}/decision",
        response_model=TurnResponse,
        dependencies=[Depends(authorize)],
    )
    async def decide_proposal(
        proposal_id: str, request: ProposalDecisionRequest
    ) -> TurnResponse:
        try:
            return runtime.orchestrator.proposals.decide(proposal_id, request.decision)
        except KeyError as error:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND, detail="proposal not found"
            ) from error
        except ValueError as error:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT, detail=str(error)
            ) from error

    return application


def main() -> None:
    settings = Settings.from_environment()
    uvicorn.run(
        create_app(),
        host=settings.host,
        port=settings.port,
        log_level="warning",
        access_log=False,
    )


if __name__ == "__main__":
    main()
