from __future__ import annotations

import hashlib
import ipaddress
import os
import re
from dataclasses import dataclass
from difflib import SequenceMatcher
from html.parser import HTMLParser
from typing import Protocol
from urllib.parse import urlsplit, urlunsplit

import httpx

from .repository import CheckpointRepository
from .schemas import CheckpointRecord, SourceReference


class FreshnessError(RuntimeError):
    pass


class ProviderUnavailable(FreshnessError):
    pass


class SavedURLFetcher(Protocol):
    name: str
    available: bool

    async def fetch(self, url: str) -> str: ...


class UnavailableSavedURLFetcher:
    name = "unavailable"
    available = False

    async def fetch(self, url: str) -> str:
        raise ProviderUnavailable("Bright Data is not configured")


class BrightDataSavedURLAdapter:
    """Fetch exactly one already-approved public URL through Web Unlocker."""

    name = "bright-data-web-unlocker"
    available = True

    def __init__(
        self,
        api_key: str,
        zone: str,
        *,
        endpoint: str = "https://api.brightdata.com/request",
        timeout_seconds: float = 25.0,
    ) -> None:
        self._api_key = api_key
        self._zone = zone
        self._endpoint = endpoint
        self._timeout = timeout_seconds

    @classmethod
    def from_environment(cls) -> SavedURLFetcher:
        api_key = os.getenv("BRIGHT_DATA_API_KEY")
        zone = os.getenv("BRIGHT_DATA_UNLOCKER_ZONE")
        if not api_key or not zone:
            return UnavailableSavedURLFetcher()
        return cls(api_key, zone)

    async def fetch(self, url: str) -> str:
        async with httpx.AsyncClient(timeout=self._timeout) as client:
            response = await client.post(
                self._endpoint,
                headers={"Authorization": f"Bearer {self._api_key}"},
                json={
                    "zone": self._zone,
                    "url": url,
                    "format": "raw",
                    "data_format": "markdown",
                },
            )
            response.raise_for_status()
        if len(response.content) > 2_000_000:
            raise FreshnessError("page exceeded the 2 MB P0 limit")
        try:
            wrapped = response.json()
        except ValueError:
            wrapped = None
        if isinstance(wrapped, dict) and isinstance(wrapped.get("body"), str):
            return wrapped["body"]
        return response.text


class _ReadableTextParser(HTMLParser):
    _SKIP = {"script", "style", "nav", "noscript", "svg", "template"}

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self._skip_depth = 0
        self.parts: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag.casefold() in self._SKIP:
            self._skip_depth += 1

    def handle_endtag(self, tag: str) -> None:
        if tag.casefold() in self._SKIP and self._skip_depth:
            self._skip_depth -= 1

    def handle_data(self, data: str) -> None:
        if not self._skip_depth and data.strip():
            self.parts.append(data)


def canonicalize_public_https_url(url: str) -> str:
    parsed = urlsplit(url.strip())
    if parsed.scheme.casefold() != "https" or not parsed.hostname:
        raise FreshnessError("only saved https URLs can be refreshed")
    if parsed.username is not None or parsed.password is not None:
        raise FreshnessError("credential-bearing URLs cannot be refreshed")
    host = parsed.hostname.casefold().rstrip(".")
    private_suffixes = (
        ".localhost",
        ".local",
        ".internal",
        ".lan",
        ".home",
        ".corp",
        ".intranet",
    )
    if host == "localhost" or "." not in host or host.endswith(private_suffixes):
        raise FreshnessError("local URLs cannot be sent to live web")
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        address = None
    if address and not address.is_global:
        raise FreshnessError("private or reserved addresses cannot be refreshed")
    port = parsed.port
    netloc = host if port in (None, 443) else f"{host}:{port}"
    path = parsed.path or "/"
    return urlunsplit(("https", netloc, path, parsed.query, ""))


def normalize_page(raw_html: str) -> str:
    parser = _ReadableTextParser()
    parser.feed(raw_html)
    text = " ".join(parser.parts) if parser.parts else raw_html
    return re.sub(r"\s+", " ", text).strip()


@dataclass(frozen=True)
class FreshnessResult:
    message: str
    source: SourceReference
    changed: bool
    normalized_text: str


class SavedURLFreshnessService:
    def __init__(
        self, repository: CheckpointRepository, fetcher: SavedURLFetcher
    ) -> None:
        self.repository = repository
        self.fetcher = fetcher

    @property
    def available(self) -> bool:
        return self.fetcher.available

    async def refresh(
        self, checkpoint: CheckpointRecord, requested_url: str
    ) -> FreshnessResult:
        canonical_url = canonicalize_public_https_url(requested_url)
        saved_artifact = next(
            (
                artifact
                for artifact in checkpoint.artifacts
                if artifact.kind == "url"
                and artifact.resource
                and canonicalize_public_https_url(artifact.resource) == canonical_url
            ),
            None,
        )
        if saved_artifact is None:
            raise FreshnessError("the URL is not saved in this checkpoint")

        raw_page = await self.fetcher.fetch(canonical_url)
        normalized = normalize_page(raw_page)
        if not normalized:
            raise FreshnessError("the refreshed page did not contain readable text")
        body_hash = hashlib.sha256(normalized.encode("utf-8")).hexdigest()
        previous = self.repository.latest_source_version(checkpoint.id, canonical_url)
        baseline_text = (
            previous.normalized_text
            if previous is not None
            else (saved_artifact.captured_text or "")
        )
        baseline_label = "previous refresh" if previous else "saved excerpt"
        similarity = (
            SequenceMatcher(None, baseline_text, normalized).ratio()
            if baseline_text
            else 0
        )
        if previous is not None:
            changed = previous.body_hash != body_hash
        elif baseline_text:
            normalized_baseline = re.sub(r"\s+", " ", baseline_text).strip().casefold()
            changed = normalized_baseline not in normalized.casefold()
        else:
            changed = True

        if previous is not None and not changed:
            version = self.repository.touch_source_version(previous.id) or previous
        else:
            version = self.repository.save_source_version(
                checkpoint_id=checkpoint.id,
                canonical_url=canonical_url,
                body_hash=body_hash,
                normalized_text=normalized,
            )
        if previous is None and baseline_text:
            detail = (
                "The current page no longer contains the saved excerpt."
                if changed
                else "The current page still contains the saved excerpt."
            )
        elif previous is None:
            detail = "Fetched the current page; there was no saved excerpt to compare."
        elif changed:
            detail = f"The saved page changed ({similarity:.0%} text similarity)."
        else:
            detail = "The saved page has not changed."
        return FreshnessResult(
            message=f"{detail} Compared with {baseline_label}.",
            source=SourceReference(
                url=canonical_url,
                title=saved_artifact.display_name,
                checked_at=version.fetched_at,
                baseline=baseline_label,
            ),
            changed=changed,
            normalized_text=normalized,
        )


def cached_source_reference(checkpoint: CheckpointRecord) -> SourceReference | None:
    artifact = next(
        (
            item
            for item in checkpoint.artifacts
            if item.kind == "url"
            and item.resource
            and item.resource.startswith("https://")
        ),
        None,
    )
    if artifact is None:
        return None
    return SourceReference(
        url=artifact.resource,
        title=artifact.display_name,
        checked_at=None,
        baseline="saved excerpt",
    )
