from pathlib import Path

import pytest

from checkpoint_agent.freshness import (
    BrightDataSavedURLAdapter,
    FreshnessError,
    SavedURLFreshnessService,
    canonicalize_public_https_url,
    normalize_page,
)
from checkpoint_agent.repository import CheckpointRepository
from checkpoint_agent.schemas import Artifact, CheckpointCreate


class FakeFetcher:
    name = "fake-live-web"
    available = True

    def __init__(self, page: str) -> None:
        self.page = page
        self.calls: list[str] = []

    async def fetch(self, url: str) -> str:
        self.calls.append(url)
        return self.page


class _WrappedResponse:
    content = b'{"body":"# Current docs"}'
    text = content.decode()

    def raise_for_status(self) -> None:
        return None

    def json(self) -> dict[str, str]:
        return {"body": "# Current docs"}


class _RecordingHTTPClient:
    def __init__(self, calls: list[dict], **kwargs) -> None:
        self.calls = calls

    async def __aenter__(self):
        return self

    async def __aexit__(self, *args) -> None:
        return None

    async def post(self, endpoint: str, **kwargs) -> _WrappedResponse:
        self.calls.append({"endpoint": endpoint, **kwargs})
        return _WrappedResponse()


def test_normalize_page_removes_scripts_and_navigation() -> None:
    text = normalize_page(
        "<nav>Menu</nav><main><h1>Current docs</h1><p>Token flow changed.</p></main>"
        "<script>steal()</script>"
    )
    assert text == "Current docs Token flow changed."


@pytest.mark.parametrize(
    "url",
    [
        "http://example.com",
        "https://localhost/private",
        "https://127.0.0.1/a",
        "https://user:secret@example.com/private",
        "https://auth.internal/private",
        "https://intranet/private",
    ],
)
def test_only_public_https_urls_are_allowed(url: str) -> None:
    with pytest.raises(FreshnessError):
        canonicalize_public_https_url(url)


async def test_bright_data_adapter_accepts_wrapped_body_and_requests_markdown(
    monkeypatch,
) -> None:
    calls: list[dict] = []
    monkeypatch.setattr(
        "checkpoint_agent.freshness.httpx.AsyncClient",
        lambda **kwargs: _RecordingHTTPClient(calls, **kwargs),
    )
    adapter = BrightDataSavedURLAdapter("key", "zone")

    body = await adapter.fetch("https://example.com/guide")

    assert body == "# Current docs"
    assert calls[0]["json"]["data_format"] == "markdown"
    assert calls[0]["json"]["format"] == "raw"


async def test_refresh_requires_exact_saved_url_and_versions_result(
    tmp_path: Path,
) -> None:
    repository = CheckpointRepository(tmp_path / "checkpoint.sqlite")
    checkpoint = repository.save(
        CheckpointCreate(
            title="LiveKit integration",
            summary="Saved setup instructions",
            artifacts=[
                Artifact(
                    kind="url",
                    display_name="LiveKit docs",
                    resource="https://docs.livekit.io/agents/",
                    captured_text="Old token flow.",
                )
            ],
        )
    )
    fetcher = FakeFetcher("<main>New token flow with sandbox IDs.</main>")
    service = SavedURLFreshnessService(repository, fetcher)

    result = await service.refresh(checkpoint, "https://docs.livekit.io/agents/")

    assert fetcher.calls == ["https://docs.livekit.io/agents/"]
    assert result.changed
    assert result.source.baseline == "saved excerpt"
    assert (
        repository.latest_source_version(checkpoint.id, result.source.url) is not None
    )
    repository.close()


async def test_first_refresh_does_not_claim_change_when_excerpt_remains(
    tmp_path: Path,
) -> None:
    repository = CheckpointRepository(tmp_path / "checkpoint.sqlite")
    checkpoint = repository.save(
        CheckpointCreate(
            title="Saved guide",
            summary="A saved public page",
            artifacts=[
                Artifact(
                    kind="url",
                    display_name="Guide",
                    resource="https://example.com/guide",
                    captured_text="Keep this exact guidance.",
                )
            ],
        )
    )
    service = SavedURLFreshnessService(
        repository, FakeFetcher("<main>Intro. Keep this exact guidance. More.</main>")
    )

    result = await service.refresh(checkpoint, "https://example.com/guide")

    assert not result.changed
    assert "still contains" in result.message
    repository.close()
