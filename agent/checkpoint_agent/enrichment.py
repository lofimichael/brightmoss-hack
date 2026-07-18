from __future__ import annotations

import hashlib
import ipaddress
import json
import os
import re
from dataclasses import dataclass
from datetime import timedelta
from typing import Protocol
from urllib.parse import urlencode, urlsplit

import httpx

from .freshness import (
    FreshnessError,
    ProviderUnavailable,
    SavedURLFetcher,
    canonicalize_public_https_url,
)
from .repository import CheckpointRepository
from .retrieval import SearchIndex
from .schemas import (
    Artifact,
    ArtifactKind,
    CheckpointCreate,
    EnrichmentRequest,
    EnrichmentResponse,
    EraseRecentResponse,
    LocalSubject,
    ObservationCreate,
    ObservationRecord,
    PublicEnrichmentCandidate,
    PublicSource,
    utc_now,
)


MAX_PUBLIC_RESULTS = 2
PUBLIC_ENRICHMENT_TTL_HOURS = 24
PUBLIC_ENRICHMENT_BACKOFF_MINUTES = 5
MAX_PUBLIC_ENRICHMENTS_PER_HOUR = 6
MIN_PUBLIC_SUBJECT_CONFIDENCE = 0.75
_ALLOWED_PUBLIC_KINDS = {
    "technology",
    "product",
    "company",
    "public_documentation",
    "academic_topic",
}
_EMAIL = re.compile(r"(?i)\b[a-z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-z0-9.-]+\.[a-z]{2,}\b")
_LOCAL_PATH = re.compile(
    r"(?i)(?:^|[\s\"'])(?:~?/|[a-z]:\\|\\\\|file://|/(?:users|home|volumes|private|tmp|var)/)"
)
_IPV4 = re.compile(r"(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?![\w.])")
_IPV6 = re.compile(r"(?i)(?<![\w:])(?:[0-9a-f]{1,4}:){2,}[0-9a-f:]{0,39}(?![\w:])")
_PRIVATE_HOST = re.compile(
    r"(?i)\b(?:localhost|[a-z0-9-]+\.(?:localhost|local|internal|lan|home|corp|intranet))\b"
)
_CREDENTIAL = re.compile(
    r"(?i)(?:\b(?:api[_-]?key|access[_-]?token|password|passwd|secret|authorization)\s*[:=]"
    r"|\bbearer\s+[a-z0-9._~-]{8,}"
    r"|\b(?:sk|ghp|github_pat|xox[abprs])[-_][a-z0-9_-]{12,}"
    r"|\bAKIA[A-Z0-9]{16}\b"
    r"|\beyJ[a-zA-Z0-9_-]{8,}\.[a-zA-Z0-9_-]{8,}\.[a-zA-Z0-9_-]{8,}\b)"
)
_LONG_OPAQUE = re.compile(r"\b[A-Za-z0-9_+/=-]{48,}\b")
_URL_WITH_CREDENTIALS = re.compile(r"(?i)https?://[^\s/@:]+:[^\s/@]+@")
_WORDS = re.compile(r"[a-z0-9]+")
_MARKDOWN_LINK = re.compile(r"\[([^\]]{1,300})\]\((https://[^\s)]+)\)")
_BARE_HTTPS = re.compile(r"https://[^\s<>()\]\[\"']+")
_PUBLIC_QUERY_SUFFIXES = {
    "technology": "official documentation latest",
    "product": "official product information latest",
    "company": "official company information latest",
    "public_documentation": "official documentation latest",
    "academic_topic": "recent academic research overview",
}
_KNOWN_PUBLIC_SUBJECTS = {
    "apple",
    "bright data",
    "brightdata",
    "livekit",
    "moss",
    "openai",
    "swift",
    "swiftui",
}
_PRIVATE_TASK_MARKERS = re.compile(
    r"(?i)\b(?:secret|private|confidential|credential|credentials|password|passwd|"
    r"api[ _-]?key|access[ _-]?token|bearer|auth|authentication|authorization|"
    r"internal[ _-]?project)\b"
)
_TASK_PHRASE_PREFIX = re.compile(
    r"(?i)^(?:working|fix|debug|review|investigate|investigating|build|implement|"
    r"write|reading|researching|prepare|preparing|ship|shipping)\b"
)


@dataclass(frozen=True)
class PolicyDecision:
    allowed: bool
    reason: str
    subject: str | None = None
    query: str | None = None
    query_hash: str = ""


class PublicEnricher(Protocol):
    name: str
    available: bool

    async def search(
        self, query: str, limit: int = MAX_PUBLIC_RESULTS
    ) -> list[PublicSource]: ...


class UnavailablePublicEnricher:
    name = "unavailable"
    available = False

    async def search(
        self, query: str, limit: int = MAX_PUBLIC_RESULTS
    ) -> list[PublicSource]:
        del query, limit
        raise ProviderUnavailable("public enrichment is not configured")


class BrightDataRemoteMCPAdapter:
    """One-key Bright Data search/scrape client using its hosted MCP server."""

    name = "bright-data-remote-mcp"
    available = True

    def __init__(self, api_key: str, *, timeout_seconds: float = 30.0) -> None:
        self._endpoint = "https://mcp.brightdata.com/mcp?" + urlencode(
            {
                "token": api_key,
                "tools": "search_engine,scrape_as_markdown",
            }
        )
        self._timeout_seconds = timeout_seconds

    def __repr__(self) -> str:
        return "BrightDataRemoteMCPAdapter(endpoint=<redacted>)"

    @classmethod
    def from_environment(cls) -> PublicEnricher:
        api_key = (os.getenv("BRIGHT_DATA_API_KEY") or "").strip()
        if not api_key:
            return UnavailablePublicEnricher()
        return cls(api_key)

    async def search(
        self, query: str, limit: int = MAX_PUBLIC_RESULTS
    ) -> list[PublicSource]:
        normalized_query = " ".join(query.split())
        rejection = _private_material_reason(normalized_query)
        if (
            not normalized_query
            or len(normalized_query) > 240
            or any(ord(character) < 32 for character in normalized_query)
            or rejection
        ):
            raise FreshnessError("outbound public query did not pass the privacy gate")
        raw = await self._call_tool(
            "search_engine", {"query": normalized_query, "engine": "google"}
        )
        return _parse_public_sources(raw, max(1, min(limit, MAX_PUBLIC_RESULTS)))

    async def fetch(self, url: str) -> str:
        canonical_url = canonicalize_public_https_url(url)
        raw = await self._call_tool("scrape_as_markdown", {"url": canonical_url})
        if len(raw.encode("utf-8")) > 2_000_000:
            raise FreshnessError("page exceeded the 2 MB P0 limit")
        return raw

    async def _call_tool(self, name: str, arguments: dict[str, str]) -> str:
        try:
            from mcp import ClientSession
            from mcp.client.streamable_http import streamable_http_client

            async with httpx.AsyncClient(
                timeout=self._timeout_seconds, trust_env=False
            ) as http_client:
                async with streamable_http_client(
                    self._endpoint, http_client=http_client
                ) as streams:
                    read_stream, write_stream = streams[0], streams[1]
                    async with ClientSession(read_stream, write_stream) as session:
                        await session.initialize()
                        result = await session.call_tool(name, arguments)
            if getattr(result, "isError", False) or getattr(result, "is_error", False):
                raise ProviderUnavailable("Bright Data MCP tool failed")
            structured = getattr(result, "structuredContent", None) or getattr(
                result, "structured_content", None
            )
            if structured:
                return json.dumps(structured, ensure_ascii=False)
            parts = [
                str(getattr(item, "text"))
                for item in getattr(result, "content", [])
                if getattr(item, "text", None)
            ]
            text = "\n".join(parts)
            if not text:
                raise ProviderUnavailable(
                    "Bright Data MCP returned no readable content"
                )
            return text[:200_000]
        except ProviderUnavailable:
            raise
        except Exception:
            # MCP exceptions may include the request URL, which contains the token.
            raise ProviderUnavailable("Bright Data MCP request failed") from None


def bright_data_fetcher_from_environment() -> SavedURLFetcher:
    """Use a custom zone when present; otherwise the hosted one-key MCP."""

    from .freshness import BrightDataSavedURLAdapter, UnavailableSavedURLFetcher

    api_key = (os.getenv("BRIGHT_DATA_API_KEY") or "").strip()
    zone = (os.getenv("BRIGHT_DATA_UNLOCKER_ZONE") or "").strip()
    if not api_key:
        return UnavailableSavedURLFetcher()
    if zone:
        return BrightDataSavedURLAdapter(api_key, zone)
    return BrightDataRemoteMCPAdapter(api_key)


def evaluate_public_candidate(
    candidate: PublicEnrichmentCandidate,
) -> PolicyDecision:
    subject = " ".join(candidate.canonical_name.split())
    query = " ".join(candidate.query.split())
    fingerprint = hashlib.sha256(
        f"{subject}\0{query}".casefold().encode("utf-8")
    ).hexdigest()
    kind = str(candidate.kind)
    if kind not in _ALLOWED_PUBLIC_KINDS:
        return PolicyDecision(False, "subject_type_not_public", query_hash=fingerprint)
    if not subject or not query or len(subject) > 160 or len(query) > 240:
        return PolicyDecision(False, "invalid_length", query_hash=fingerprint)
    combined = f"{subject} {query}"
    if any(ord(character) < 32 for character in combined):
        return PolicyDecision(False, "control_characters", query_hash=fingerprint)
    rejection = _private_material_reason(combined)
    if rejection:
        return PolicyDecision(False, rejection, query_hash=fingerprint)
    subject_tokens = {
        token for token in _WORDS.findall(subject.casefold()) if len(token) > 2
    }
    query_tokens = set(_WORDS.findall(query.casefold()))
    if subject_tokens and not subject_tokens.intersection(query_tokens):
        return PolicyDecision(False, "query_subject_mismatch", query_hash=fingerprint)
    expected_query = f"{subject} {_PUBLIC_QUERY_SUFFIXES[kind]}"
    if query != expected_query:
        return PolicyDecision(False, "query_template_mismatch", query_hash=fingerprint)
    return PolicyDecision(
        True,
        "public_subject_allowed",
        subject=subject,
        query=query,
        query_hash=fingerprint,
    )


def public_candidate_for_subject(
    subject: LocalSubject,
) -> PublicEnrichmentCandidate | None:
    """Build a network-safe query using only a public label and generic terms.

    Locally extracted keywords improve local retrieval, but intentionally do not
    enter this query: they can contain a private codename even when a model labels
    the parent subject as public.
    """

    kind = str(subject.kind)
    canonical_name = " ".join(subject.canonical_name.split())
    suffix = _PUBLIC_QUERY_SUFFIXES.get(kind)
    if (
        not suffix
        or subject.confidence < MIN_PUBLIC_SUBJECT_CONFIDENCE
        or _private_material_reason(canonical_name)
        or any(ord(character) < 32 for character in canonical_name)
    ):
        return None
    candidate = PublicEnrichmentCandidate(
        canonical_name=canonical_name,
        kind=kind,
        query=f"{canonical_name} {suffix}",
    )
    return candidate if evaluate_public_candidate(candidate).allowed else None


def _automatic_subject_is_safe(subject: LocalSubject, draft: ObservationCreate) -> bool:
    """Distrust local classifications before any automatic network boundary."""

    canonical = " ".join(subject.canonical_name.split())
    normalized = " ".join(_WORDS.findall(canonical.casefold()))
    window = " ".join(_WORDS.findall((draft.window_title or "").casefold()))
    intent = " ".join(
        _WORDS.findall(
            (draft.likely_intent.summary if draft.likely_intent else "").casefold()
        )
    )
    words = _WORDS.findall(canonical)
    locally_safe = not (
        (window and normalized == window)
        or (intent and normalized == intent)
        or _PRIVATE_TASK_MARKERS.search(canonical)
        or _TASK_PHRASE_PREFIX.search(canonical)
        or len(words) > 6
        or any(separator in canonical for separator in ("—", "|", "\n", "\t"))
    )
    return locally_safe and _public_subject_is_corroborated(
        canonical, [draft.document_resource] if draft.document_resource else []
    )


def _public_subject_is_corroborated(canonical_name: str, resources: list[str]) -> bool:
    """Require a known public label or its presence in a validated public host."""

    normalized = " ".join(_WORDS.findall(canonical_name.casefold()))
    if normalized in _KNOWN_PUBLIC_SUBJECTS:
        return True
    compact = "".join(_WORDS.findall(canonical_name.casefold()))
    if len(compact) < 4:
        return False
    for resource in resources:
        try:
            public_url = canonicalize_public_https_url(resource)
        except (FreshnessError, ValueError):
            continue
        hostname = urlsplit(public_url).hostname or ""
        compact_host = "".join(_WORDS.findall(hostname.casefold()))
        if compact in compact_host:
            return True
    return False


def _private_material_reason(text: str) -> str | None:
    if _EMAIL.search(text):
        return "contains_email"
    if _LOCAL_PATH.search(text) or "\\" in text:
        return "contains_local_path"
    if _URL_WITH_CREDENTIALS.search(text):
        return "contains_credentials"
    if _CREDENTIAL.search(text) or _LONG_OPAQUE.search(text):
        return "contains_credentials"
    if _PRIVATE_HOST.search(text):
        return "contains_private_host"
    if _contains_ip_address(text):
        return "contains_ip_address"
    if re.search(r"(?i)\bhttps?://", text):
        return "contains_raw_url"
    return None


def _contains_ip_address(text: str) -> bool:
    for match in [*_IPV4.findall(text), *_IPV6.findall(text)]:
        try:
            ipaddress.ip_address(match.rstrip(":"))
            return True
        except ValueError:
            continue
    return False


def _parse_public_sources(raw: str, limit: int) -> list[PublicSource]:
    candidates: list[tuple[str, str, str | None]] = []
    try:
        parsed = json.loads(raw)
    except (TypeError, ValueError):
        parsed = None

    def walk(value: object, depth: int = 0) -> None:
        if depth > 5 or len(candidates) >= limit * 4:
            return
        if isinstance(value, dict):
            url = value.get("url") or value.get("link")
            if isinstance(url, str):
                title = value.get("title") or value.get("name") or url
                snippet = (
                    value.get("description")
                    or value.get("snippet")
                    or value.get("text")
                )
                candidates.append(
                    (
                        str(title)[:300],
                        url,
                        str(snippet)[:600] if snippet else None,
                    )
                )
            for nested in value.values():
                walk(nested, depth + 1)
        elif isinstance(value, list):
            for nested in value:
                walk(nested, depth + 1)

    if parsed is not None:
        walk(parsed)
    if not candidates:
        for title, url in _MARKDOWN_LINK.findall(raw):
            candidates.append((title, url, None))
        for url in _BARE_HTTPS.findall(raw):
            candidates.append((url, url, None))

    sources: list[PublicSource] = []
    seen: set[str] = set()
    for title, url, snippet in candidates:
        try:
            canonical = canonicalize_public_https_url(url.rstrip(".,;"))
        except (FreshnessError, ValueError):
            continue
        if canonical in seen:
            continue
        seen.add(canonical)
        sources.append(
            PublicSource(
                title=" ".join(title.split())[:300], url=canonical, snippet=snippet
            )
        )
        if len(sources) >= limit:
            break
    return sources


class KnowledgeGraphService:
    def __init__(
        self,
        repository: CheckpointRepository,
        index: SearchIndex,
        enricher: PublicEnricher,
    ) -> None:
        self.repository = repository
        self.index = index
        self.enricher = enricher

    async def save_observation(self, draft: ObservationCreate) -> ObservationRecord:
        checkpoint = None
        if not draft.checkpoint_id:
            checkpoint = self._update_ambient_episode(draft)
            draft = draft.model_copy(update={"checkpoint_id": checkpoint.id})
        record = self.repository.save_observation(draft)
        assert draft.checkpoint_id is not None
        checkpoint = checkpoint or self.repository.get(draft.checkpoint_id)
        if checkpoint is not None:
            await self.index.upsert(checkpoint)
        await self._refresh_graph_documents(draft.checkpoint_id)
        enrichment_result: EnrichmentResponse | None = None
        if draft.allow_public_enrichment:
            candidate = self._novel_public_candidate(draft)
            if candidate is not None:
                # Observation durability is authoritative. Optional provider
                # failure is captured as an enrichment status and never rolls
                # back the private memory.
                enrichment_result = await self.enrich(
                    EnrichmentRequest(
                        checkpoint_id=draft.checkpoint_id,
                        observation_id=record.id,
                        candidate=candidate,
                        allow_public_enrichment=True,
                    )
                )
        return record.model_copy(update={"enrichment": enrichment_result})

    def _novel_public_candidate(
        self, draft: ObservationCreate
    ) -> PublicEnrichmentCandidate | None:
        cached_fallback: PublicEnrichmentCandidate | None = None
        for subject in sorted(
            draft.subjects,
            key=lambda item: (item.confidence, item.canonical_name.casefold()),
            reverse=True,
        ):
            if not _automatic_subject_is_safe(subject, draft):
                continue
            candidate = public_candidate_for_subject(subject)
            if candidate is None:
                continue
            decision = evaluate_public_candidate(candidate)
            if not self.repository.recent_enrichment(decision.query_hash):
                return candidate
            # Reusing already-sanitized public context is not a new provider
            # expansion. Link at most one cached result so the timeline can show
            # provenance without another network request.
            cached_fallback = cached_fallback or candidate
        return cached_fallback

    def _update_ambient_episode(self, draft: ObservationCreate):
        """Make the private daily episode useful without any cloud planner."""

        captured_day = draft.captured_at.astimezone().date()
        checkpoint_id = f"ambient-{captured_day.isoformat()}"
        day_label = captured_day.strftime("%b %d").replace(" 0", " ")
        existing = self.repository.get(checkpoint_id)
        if draft.likely_intent:
            summary = draft.likely_intent.summary
        elif draft.subjects:
            summary = "Working with " + ", ".join(
                subject.canonical_name for subject in draft.subjects[:3]
            )
        elif draft.window_title:
            summary = f"Working on {draft.window_title}"
        else:
            summary = (
                f"Using {draft.application_name or draft.app_bundle_id or 'the Mac'}"
            )

        new_artifacts: list[Artifact] = []
        if draft.application_name or draft.app_bundle_id:
            app_name = draft.application_name or draft.app_bundle_id or "Application"
            display_name = (
                f"{app_name} — {draft.window_title}" if draft.window_title else app_name
            )
            new_artifacts.append(
                Artifact(
                    kind=ArtifactKind.APP,
                    display_name=display_name[:500],
                    bundle_id=draft.app_bundle_id,
                    captured_text=draft.window_title,
                    captured_at=draft.captured_at,
                )
            )
        resource = (draft.document_resource or "").strip()
        if resource.startswith("https://"):
            new_artifacts.append(
                Artifact(
                    kind=ArtifactKind.URL,
                    display_name=(draft.window_title or resource)[:500],
                    resource=resource,
                    captured_text=draft.window_title,
                    captured_at=draft.captured_at,
                )
            )
        elif resource.startswith("/"):
            new_artifacts.append(
                Artifact(
                    kind=ArtifactKind.FILE,
                    display_name=(draft.window_title or resource.rsplit("/", 1)[-1])[
                        :500
                    ],
                    resource=resource,
                    captured_text=draft.window_title,
                    captured_at=draft.captured_at,
                )
            )

        combined = [*(existing.artifacts if existing else []), *new_artifacts]
        seen: set[tuple[str, str]] = set()
        recent_unique: list[Artifact] = []
        for artifact in reversed(combined):
            key = (
                str(artifact.kind),
                artifact.resource or artifact.bundle_id or artifact.display_name,
            )
            if key in seen:
                continue
            seen.add(key)
            recent_unique.append(artifact)
            if len(recent_unique) == 8:
                break
        return self.repository.save(
            CheckpointCreate(
                id=checkpoint_id,
                title=f"Workspace memory · {day_label}",
                summary=summary[:500],
                artifacts=list(reversed(recent_unique)),
            )
        )

    async def enrich(self, request: EnrichmentRequest) -> EnrichmentResponse:
        if self.repository.get(request.checkpoint_id) is None:
            raise KeyError(request.checkpoint_id)
        if request.observation_id and (
            self.repository.memory_checkpoint_id(request.observation_id)
            != request.checkpoint_id
        ):
            raise ValueError("observation does not belong to checkpoint")
        if not request.allow_public_enrichment:
            return self._rejected_enrichment(
                request, "public_enrichment_not_authorized"
            )
        decision = evaluate_public_candidate(request.candidate)
        if not decision.allowed:
            return self._rejected_enrichment(request, decision.reason)

        assert decision.subject is not None and decision.query is not None
        if not _public_subject_is_corroborated(
            decision.subject,
            self.repository.public_context_resources(
                request.checkpoint_id, observation_id=request.observation_id
            ),
        ):
            return self._rejected_enrichment(request, "public_subject_not_corroborated")
        checked_at = utc_now()
        subject_node_id = request.subject_node_id
        if subject_node_id and not self.repository.subject_node_matches(
            subject_node_id,
            request.checkpoint_id,
            canonical_name=decision.subject,
            subject_kind=str(request.candidate.kind),
        ):
            raise ValueError("subject node does not match the public candidate")
        if not subject_node_id and request.observation_id:
            subject_node_id = self.repository.private_subject_node_for_observation(
                checkpoint_id=request.checkpoint_id,
                observation_id=request.observation_id,
                canonical_name=decision.subject,
                subject_kind=str(request.candidate.kind),
            )
        if not subject_node_id:
            subject_node_id = self.repository.ensure_public_subject_node(
                checkpoint_id=request.checkpoint_id,
                canonical_name=decision.subject,
                subject_kind=str(request.candidate.kind),
                observation_id=request.observation_id,
            )

        recent = self.repository.recent_enrichment(decision.query_hash)
        if recent:
            recent_status = str(recent["status"])
            sources = recent["sources"]
            response_status = (
                "cached"
                if recent_status in {"complete", "cached"} and sources
                else recent_status
            )
            if response_status == "running":
                response_status = "failed"
            job_id = self.repository.create_enrichment_job(
                checkpoint_id=request.checkpoint_id,
                subject_node_id=subject_node_id,
                public_subject=decision.subject,
                public_query=decision.query,
                query_hash=decision.query_hash,
                policy_result="allowed",
                policy_reason="recent_attempt_cached",
                status=response_status,
                observation_id=request.observation_id,
                expires_at=recent["expires_at"],
            )
            self.repository.complete_enrichment_job(
                job_id, status=response_status, sources=sources
            )
            if sources:
                self.repository.attach_public_sources(
                    checkpoint_id=request.checkpoint_id,
                    subject_node_id=subject_node_id,
                    sources=sources,
                    observation_id=request.observation_id,
                )
                await self._refresh_graph_documents(request.checkpoint_id)
            return EnrichmentResponse(
                job_id=job_id,
                status=response_status,
                policy="allowed",
                policy_reason="recent_attempt_cached",
                outbound_query=decision.query,
                sources=sources,
                checked_at=recent["checked_at"],
            )

        if not self.enricher.available:
            job_id = self.repository.create_enrichment_job(
                checkpoint_id=request.checkpoint_id,
                subject_node_id=subject_node_id,
                public_subject=decision.subject,
                public_query=decision.query,
                query_hash=decision.query_hash,
                policy_result="allowed",
                policy_reason=decision.reason,
                status="provider_unavailable",
                observation_id=request.observation_id,
                expires_at=checked_at
                + timedelta(minutes=PUBLIC_ENRICHMENT_BACKOFF_MINUTES),
            )
            return EnrichmentResponse(
                job_id=job_id,
                status="provider_unavailable",
                policy="allowed",
                policy_reason=decision.reason,
                outbound_query=decision.query,
                checked_at=checked_at,
            )

        one_hour_ago = utc_now() - timedelta(hours=1)
        if (
            self.repository.network_enrichment_attempts_since(one_hour_ago)
            >= MAX_PUBLIC_ENRICHMENTS_PER_HOUR
        ):
            job_id = self.repository.create_enrichment_job(
                checkpoint_id=request.checkpoint_id,
                subject_node_id=subject_node_id,
                public_subject=decision.subject,
                public_query=decision.query,
                query_hash=decision.query_hash,
                policy_result="allowed",
                policy_reason="hourly_budget_exhausted",
                status="rate_limited",
                ttl_hours=1,
                observation_id=request.observation_id,
            )
            return EnrichmentResponse(
                job_id=job_id,
                status="rate_limited",
                policy="allowed",
                policy_reason="hourly_budget_exhausted",
                outbound_query=decision.query,
                checked_at=checked_at,
            )

        job_id = self.repository.create_enrichment_job(
            checkpoint_id=request.checkpoint_id,
            subject_node_id=subject_node_id,
            public_subject=decision.subject,
            public_query=decision.query,
            query_hash=decision.query_hash,
            policy_result="allowed",
            policy_reason=decision.reason,
            status="running",
            observation_id=request.observation_id,
            expires_at=checked_at
            + timedelta(minutes=PUBLIC_ENRICHMENT_BACKOFF_MINUTES),
            network_attempted=True,
        )
        try:
            sources = (await self.enricher.search(decision.query, MAX_PUBLIC_RESULTS))[
                :MAX_PUBLIC_RESULTS
            ]
        except Exception:
            checked_at = self.repository.complete_enrichment_job(
                job_id,
                status="failed",
                sources=[],
                expires_at=utc_now()
                + timedelta(minutes=PUBLIC_ENRICHMENT_BACKOFF_MINUTES),
            )
            return EnrichmentResponse(
                job_id=job_id,
                status="failed",
                policy="allowed",
                policy_reason=decision.reason,
                outbound_query=decision.query,
                checked_at=checked_at,
            )
        if not sources:
            checked_at = self.repository.complete_enrichment_job(
                job_id,
                status="failed",
                sources=[],
                expires_at=utc_now()
                + timedelta(minutes=PUBLIC_ENRICHMENT_BACKOFF_MINUTES),
            )
            return EnrichmentResponse(
                job_id=job_id,
                status="failed",
                policy="allowed",
                policy_reason=decision.reason,
                outbound_query=decision.query,
                checked_at=checked_at,
            )
        checked_at = self.repository.complete_enrichment_job(
            job_id,
            status="complete",
            sources=sources,
            expires_at=utc_now() + timedelta(hours=PUBLIC_ENRICHMENT_TTL_HOURS),
        )
        self.repository.attach_public_sources(
            checkpoint_id=request.checkpoint_id,
            subject_node_id=subject_node_id,
            sources=sources,
            observation_id=request.observation_id,
        )
        await self._refresh_graph_documents(request.checkpoint_id)
        return EnrichmentResponse(
            job_id=job_id,
            status="complete",
            policy="allowed",
            policy_reason=decision.reason,
            outbound_query=decision.query,
            sources=sources,
            checked_at=checked_at,
        )

    def _rejected_enrichment(
        self, request: EnrichmentRequest, reason: str
    ) -> EnrichmentResponse:
        # Rejected input can itself be a credential. Persist only a reason-bound
        # marker, never the candidate, its query, or a secret-derived fingerprint.
        checked_at = utc_now()
        rejected_marker = hashlib.sha256(f"rejected:{reason}".encode()).hexdigest()
        job_id = self.repository.create_enrichment_job(
            checkpoint_id=request.checkpoint_id,
            subject_node_id=None,
            public_subject="[rejected]",
            public_query="[rejected]",
            query_hash=rejected_marker,
            policy_result="rejected",
            policy_reason=reason,
            status="rejected",
            observation_id=request.observation_id,
        )
        return EnrichmentResponse(
            job_id=job_id,
            status="rejected",
            policy="rejected",
            policy_reason=reason,
            checked_at=checked_at,
        )

    async def erase_recent(self, minutes: int = 15) -> EraseRecentResponse:
        result = self.repository.erase_recent(minutes)
        await self.index.rebuild(list(self.repository.all_records()))
        await self._upsert_documents(self.repository.graph_documents())
        return result

    async def delete_memory_item(self, observation_id: str) -> tuple[bool, bool]:
        checkpoint_id = self.repository.memory_checkpoint_id(observation_id)
        if checkpoint_id is None:
            return False, False
        before_ids = {
            document["id"]
            for document in self.repository.graph_documents(checkpoint_id=checkpoint_id)
        }
        deleted, checkpoint_deleted = self.repository.delete_memory_item(observation_id)
        if not deleted:
            return False, False
        delete_graph = getattr(self.index, "delete_graph_documents", None)
        if checkpoint_deleted:
            await self.index.delete(checkpoint_id)
            if delete_graph is not None:
                await delete_graph(list(before_ids))
            return True, True
        current_documents = self.repository.graph_documents(checkpoint_id=checkpoint_id)
        current_ids = {document["id"] for document in current_documents}
        if delete_graph is not None and before_ids - current_ids:
            await delete_graph(list(before_ids - current_ids))
        checkpoint = self.repository.get(checkpoint_id)
        if checkpoint is not None:
            await self.index.upsert(checkpoint)
        await self._upsert_documents(current_documents)
        return True, False

    async def _refresh_graph_documents(self, checkpoint_id: str) -> None:
        await self._upsert_documents(
            self.repository.graph_documents(checkpoint_id=checkpoint_id)
        )

    async def _upsert_documents(self, documents: list[dict]) -> None:
        upsert = getattr(self.index, "upsert_graph_documents", None)
        if upsert is not None:
            await upsert(documents)
