from __future__ import annotations

from datetime import datetime, timezone
from enum import Enum
from typing import Annotated, Literal
from uuid import uuid4

from pydantic import BaseModel, ConfigDict, Field, SecretStr, StringConstraints


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


NonBlank = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1)]
ShortText = Annotated[
    str, StringConstraints(strip_whitespace=True, min_length=1, max_length=500)
]
Keyword = Annotated[
    str, StringConstraints(strip_whitespace=True, min_length=1, max_length=80)
]


class TolerantModel(BaseModel):
    """Wire models ignore additive fields so Swift and Python can roll independently."""

    model_config = ConfigDict(extra="ignore", use_enum_values=True)


class ArtifactKind(str, Enum):
    APP = "app"
    FILE = "file"
    URL = "url"
    SELECTION = "selection"
    NOTE = "note"


class Artifact(TolerantModel):
    id: str = Field(default_factory=lambda: str(uuid4()))
    kind: ArtifactKind
    display_name: NonBlank
    bundle_id: str | None = None
    resource: str | None = None
    captured_text: str | None = None
    captured_at: datetime = Field(default_factory=utc_now)


class CheckpointCreate(TolerantModel):
    id: str | None = None
    title: NonBlank
    summary: NonBlank
    next_step: str | None = None
    artifacts: list[Artifact] = Field(default_factory=list)


class CheckpointRecord(TolerantModel):
    id: str
    title: str
    summary: str
    next_step: str | None = None
    artifacts: list[Artifact] = Field(default_factory=list)
    status: Literal["saved"] = "saved"
    created_at: datetime
    saved_at: datetime


class Modality(str, Enum):
    TYPED = "typed"
    VOICE = "voice"


class UserTurn(TolerantModel):
    text: NonBlank
    modality: Modality = Modality.TYPED
    request_id: str | None = None
    checkpoint_id: str | None = None
    url: str | None = None
    # Consent is carried on every turn. False is deliberately the compatibility
    # default so a missing/old client field can never authorize a network call.
    allow_public_enrichment: bool = False


class OutcomeKind(str, Enum):
    MESSAGE = "message"
    RESULT_CARD = "result_card"
    CONFIRMATION_CARD = "confirmation_card"
    PROGRESS_CARD = "progress_card"


class SourceReference(TolerantModel):
    url: str
    title: str | None = None
    excerpt: str | None = None
    checked_at: datetime | None = None
    baseline: str | None = None


class ProposedAction(TolerantModel):
    """A reviewed native target. Swift decides how (and whether) to execute it."""

    id: str = Field(default_factory=lambda: str(uuid4()))
    kind: Literal["activateApp", "openFile", "openURL", "revealInFinder"]
    display_name: str
    bundle_id: str | None = None
    resource: str | None = None


class TurnResponse(TolerantModel):
    request_id: str
    kind: OutcomeKind
    message: str
    checkpoint: CheckpointRecord | None = None
    sources: list[SourceReference] = Field(default_factory=list)
    proposed_actions: list[ProposedAction] = Field(default_factory=list)
    provider_disclosure: list[str] = Field(default_factory=list)
    proposal_id: str | None = None
    status: Literal["approved", "cancelled"] | None = None


class ProposalDecision(str, Enum):
    APPROVE = "approve"
    CANCEL = "cancel"


class ProposalDecisionRequest(TolerantModel):
    decision: ProposalDecision


class ProposalDecisionResponse(TolerantModel):
    proposal_id: str
    status: Literal["approved", "cancelled"]
    message: str
    proposed_actions: list[ProposedAction] = Field(default_factory=list)


class HealthResponse(TolerantModel):
    api_version: Literal[2] = 2
    status: Literal["ok"] = "ok"
    database: Literal["ready"] = "ready"
    search: str
    planner: str
    freshness: str


class SourceVersion(TolerantModel):
    id: str
    checkpoint_id: str
    canonical_url: str
    fetched_at: datetime
    body_hash: str
    normalized_text: str
    is_current: bool = True


class ExtractionMethod(str, Enum):
    METADATA = "metadata"
    ACCESSIBILITY = "accessibility"
    OCR = "ocr"


class SubjectKind(str, Enum):
    TECHNOLOGY = "technology"
    PRODUCT = "product"
    COMPANY = "company"
    PUBLIC_DOCUMENTATION = "public_documentation"
    ACADEMIC_TOPIC = "academic_topic"
    PERSON = "person"
    PROJECT = "project"
    OTHER = "other"


class LocalSubject(TolerantModel):
    canonical_name: Annotated[
        str, StringConstraints(strip_whitespace=True, min_length=1, max_length=160)
    ]
    kind: SubjectKind = SubjectKind.OTHER
    keywords: list[Keyword] = Field(default_factory=list, max_length=12)
    confidence: float = Field(default=1.0, ge=0, le=1)


class InferredIntent(TolerantModel):
    summary: ShortText
    confidence: float = Field(default=0.5, ge=0, le=1)


class PublicEnrichmentCandidate(TolerantModel):
    """The only observation-derived object eligible to cross the network boundary."""

    canonical_name: Annotated[
        str, StringConstraints(strip_whitespace=True, min_length=1, max_length=160)
    ]
    kind: SubjectKind
    query: Annotated[
        str, StringConstraints(strip_whitespace=True, min_length=1, max_length=240)
    ]


class ObservationCreate(TolerantModel):
    # Passive capture does not ask the consumer to create a session first. The
    # helper groups an omitted value into a private per-day ambient episode.
    checkpoint_id: NonBlank | None = None
    id: str | None = None
    captured_at: datetime = Field(default_factory=utc_now)
    application_name: Annotated[str, StringConstraints(max_length=255)] | None = None
    app_bundle_id: Annotated[str, StringConstraints(max_length=255)] | None = None
    window_title: Annotated[str, StringConstraints(max_length=500)] | None = None
    document_resource: Annotated[str, StringConstraints(max_length=2_000)] | None = None
    extracted_text: Annotated[str, StringConstraints(max_length=20_000)] | None = None
    extraction_method: ExtractionMethod = ExtractionMethod.METADATA
    subjects: list[LocalSubject] = Field(default_factory=list, max_length=12)
    likely_intent: InferredIntent | None = None
    # This opt-in is evaluated again by the helper. Local storage and graph
    # accretion never depend on it.
    allow_public_enrichment: bool = False


class PublicSource(TolerantModel):
    title: str
    url: str
    snippet: str | None = None


class ObservationEnrichmentResult(TolerantModel):
    job_id: str
    status: Literal[
        "complete",
        "cached",
        "rejected",
        "provider_unavailable",
        "failed",
        "rate_limited",
    ]
    policy: Literal["allowed", "rejected"]
    policy_reason: str
    outbound_query: str | None = None
    sources: list[PublicSource] = Field(default_factory=list)
    checked_at: datetime


class ObservationRecord(TolerantModel):
    id: str
    checkpoint_id: str
    captured_at: datetime
    content_hash: str
    extraction_method: ExtractionMethod
    node_ids: list[str] = Field(default_factory=list)
    evidence_id: str
    enrichment: ObservationEnrichmentResult | None = None


class GraphNode(TolerantModel):
    id: str
    checkpoint_id: str
    kind: Literal["episode", "intent", "entity", "artifact", "claim", "web_source"]
    label: str
    sensitivity: Literal["private", "public"]
    confidence: float
    created_at: datetime
    updated_at: datetime


class GraphEdge(TolerantModel):
    id: str
    checkpoint_id: str
    from_node_id: str
    to_node_id: str
    kind: str
    confidence: float
    evidence_id: str | None = None
    observed_at: datetime


class GraphEvidence(TolerantModel):
    id: str
    checkpoint_id: str
    source_kind: Literal["local_observation", "public_web"]
    source_ref: str | None = None
    excerpt: str
    captured_at: datetime


class GraphNeighborhood(TolerantModel):
    checkpoint_id: str
    nodes: list[GraphNode] = Field(default_factory=list)
    edges: list[GraphEdge] = Field(default_factory=list)
    evidence: list[GraphEvidence] = Field(default_factory=list)


class EnrichmentRequest(TolerantModel):
    checkpoint_id: NonBlank
    subject_node_id: str | None = None
    observation_id: str | None = None
    candidate: PublicEnrichmentCandidate
    # Explicit on every manual request. A missing field from an older client is
    # denial and therefore can never authorize an outbound provider call.
    allow_public_enrichment: bool = False


class EnrichmentResponse(ObservationEnrichmentResult):
    """Standalone enrichment response; also embeds in ObservationRecord."""


class MemoryItem(TolerantModel):
    id: str
    checkpoint_id: str
    captured_at: datetime
    application_name: str | None = None
    app_bundle_id: str | None = None
    window_title: str | None = None
    document_label: str | None = None
    extraction_method: ExtractionMethod
    subjects: list[LocalSubject] = Field(default_factory=list)
    likely_intent: InferredIntent | None = None
    public_sources: list[PublicSource] = Field(default_factory=list)
    enrichment_status: str | None = None
    outbound_query: str | None = None
    provenance: list[str] = Field(default_factory=lambda: ["local"])


class MemoryItemsResponse(TolerantModel):
    items: list[MemoryItem] = Field(default_factory=list)
    total: int = Field(ge=0)


class MemoryEnrichmentItem(TolerantModel):
    """A privacy-bounded row in the public-knowledge activity ledger."""

    id: str
    job_id: str
    checkpoint_id: str
    checkpoint_title: str | None = None
    observation_id: str | None = None
    checked_at: datetime
    public_subject: str
    outbound_query: str
    status: str
    policy: str
    policy_reason: str
    sources: list[PublicSource] = Field(default_factory=list, max_length=2)
    source_count: int = Field(ge=0)
    captured_at: datetime | None = None
    application_name: str | None = None
    window_title: str | None = None
    document_label: str | None = None


class MemoryEnrichmentsResponse(TolerantModel):
    items: list[MemoryEnrichmentItem] = Field(default_factory=list)
    total: int = Field(ge=0)


class MemorySubjectAggregate(TolerantModel):
    canonical_name: str
    kind: SubjectKind
    keywords: list[str] = Field(default_factory=list)
    count: int = Field(ge=1)
    first_seen: datetime
    last_seen: datetime
    apps: list[str] = Field(default_factory=list)
    public_sources: list[PublicSource] = Field(default_factory=list)


class MemorySubjectsResponse(TolerantModel):
    subjects: list[MemorySubjectAggregate] = Field(default_factory=list)
    total: int = Field(ge=0)


class MemoryStats(TolerantModel):
    total_memories: int = Field(ge=0)
    total_subjects: int = Field(ge=0)
    enriched_memories: int = Field(ge=0)
    public_sources: int = Field(ge=0)
    categories: dict[str, int] = Field(default_factory=dict)


class MemoryDeleteResponse(TolerantModel):
    observation_id: str
    deleted: bool
    checkpoint_deleted: bool


class EraseRecentRequest(TolerantModel):
    minutes: int = Field(default=15, ge=1, le=60)


class EraseRecentResponse(TolerantModel):
    erased_at: datetime
    since: datetime
    observations: int
    nodes: int
    edges: int
    evidence: int
    enrichment_jobs: int
    source_versions: int


class ProviderConfigurationRequest(BaseModel):
    """Write-only provider material received from the app's Keychain bridge."""

    model_config = ConfigDict(extra="forbid")

    bright_data_api_key: SecretStr | None = Field(
        default=None, min_length=1, max_length=4_096, repr=False
    )
    moss_project_id: SecretStr | None = Field(
        default=None, min_length=1, max_length=1_024, repr=False
    )
    moss_project_key: SecretStr | None = Field(
        default=None, min_length=1, max_length=4_096, repr=False
    )
    moss_credential: SecretStr | None = Field(
        default=None,
        min_length=1,
        max_length=8_192,
        repr=False,
        description=(
            "Write-only JSON bundle containing project_id and project_key. "
            "Moss does not support a key-only local session."
        ),
    )
    openai_api_key: SecretStr | None = Field(
        default=None, min_length=1, max_length=4_096, repr=False
    )
    livekit_url: SecretStr | None = Field(
        default=None, min_length=1, max_length=2_048, repr=False
    )
    livekit_api_key: SecretStr | None = Field(
        default=None, min_length=1, max_length=4_096, repr=False
    )
    livekit_api_secret: SecretStr | None = Field(
        default=None, min_length=1, max_length=4_096, repr=False
    )
    livekit_sandbox_id: SecretStr | None = Field(
        default=None, min_length=1, max_length=1_024, repr=False
    )
    livekit_agent_name: (
        Annotated[
            str, StringConstraints(strip_whitespace=True, min_length=1, max_length=128)
        ]
        | None
    ) = Field(default=None, repr=False)


class ProviderCapabilityStatus(TolerantModel):
    bright_data: Literal["ready", "not_configured", "unavailable"]
    bright_data_mode: Literal["remote_mcp", "web_unlocker", "none"]
    moss: Literal["ready", "not_configured", "unavailable"]
    planner: Literal["local", "openai"]
    voice: Literal["not_configured", "restart_required"]
    local_retrieval: Literal[True] = True
