"""LiveKit voice worker for CHECKPOINT.

The worker is intentionally a read-only voice surface. Its only tool calls the
local CHECKPOINT helper's ``POST /turn`` endpoint; it cannot save or delete
checkpoints, approve proposals, or execute native macOS actions.

Speech and tool routing use LiveKit Inference through the user's LiveKit
project. The defaults require no direct OpenAI, Deepgram, Google, or Cartesia
credentials.

Run it with, for example::

    python -m checkpoint_agent.voice_agent dev
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

import httpx

from .config import _load_operator_environment


_load_operator_environment()

DEFAULT_AGENT_NAME = "checkpoint"
DEFAULT_STT_MODEL = "deepgram/flux-general"
DEFAULT_LLM_MODEL = "google/gemma-4-31b-it"
DEFAULT_TTS_MODEL = "cartesia/sonic-3"
DEFAULT_TTS_VOICE = "9626c31c-bec5-4cca-baa8-f8ba9e84c8bc"
DEFAULT_LANGUAGE = "en"
DEFAULT_CONNECTION_FILE = (
    Path.home()
    / "Library"
    / "Application Support"
    / "Checkpoint"
    / "agent-connection.json"
)
MAX_QUERY_CHARACTERS = 2_000


def _env_or_default(name: str, default: str) -> str:
    value = os.getenv(name, "").strip()
    return value or default


class HelperConnectionError(RuntimeError):
    """Raised when the local helper connection descriptor is unavailable or unsafe."""


@dataclass(frozen=True)
class HelperConnection:
    base_url: str
    token: str


def _connection_file_path() -> Path:
    explicit_path = os.getenv("CHECKPOINT_CONNECTION_FILE")
    if explicit_path:
        return Path(explicit_path).expanduser()

    data_dir = os.getenv("CHECKPOINT_DATA_DIR")
    if data_dir:
        return Path(data_dir).expanduser() / "agent-connection.json"

    return DEFAULT_CONNECTION_FILE


def _read_helper_connection() -> HelperConnection:
    path = _connection_file_path()
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise HelperConnectionError(
            "The local CHECKPOINT helper is not running."
        ) from error
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise HelperConnectionError(
            "The local CHECKPOINT helper connection file is unreadable."
        ) from error

    if not isinstance(raw, dict):
        raise HelperConnectionError("The local helper connection file is invalid.")

    supplied_url = raw.get("base_url")
    token = raw.get("token")
    if not isinstance(supplied_url, str) or not isinstance(token, str) or not token:
        raise HelperConnectionError("The local helper connection file is incomplete.")

    parsed = urlsplit(supplied_url)
    try:
        port = parsed.port
    except ValueError as error:
        raise HelperConnectionError("The local helper address is invalid.") from error

    # Never allow a connection descriptor to turn this tool into an arbitrary
    # network client. The helper itself binds only to the IPv4 loopback address.
    if (
        parsed.scheme != "http"
        or parsed.hostname != "127.0.0.1"
        or port is None
        or parsed.username is not None
        or parsed.password is not None
        or parsed.path not in {"", "/"}
        or parsed.query
        or parsed.fragment
    ):
        raise HelperConnectionError("The local helper address is not loopback-only.")

    return HelperConnection(base_url=f"http://127.0.0.1:{port}", token=token)


def _spoken_result(payload: Any) -> dict[str, Any]:
    """Return only the fields the voice LLM needs to describe a retrieval result.

    Artifact resources, captured text, proposal IDs, and proposed action targets
    are intentionally omitted so local paths and executable targets do not cross
    the voice model boundary.
    """

    if not isinstance(payload, dict):
        return {
            "status": "unavailable",
            "message": "CHECKPOINT returned an unexpected response.",
        }

    result: dict[str, Any] = {
        "status": "ok",
        "kind": str(payload.get("kind") or "message"),
        "message": str(payload.get("message") or "No matching checkpoint was found."),
    }

    checkpoint = payload.get("checkpoint")
    if isinstance(checkpoint, dict):
        result["checkpoint"] = {
            key: str(checkpoint[key])
            for key in ("title", "summary", "next_step")
            if checkpoint.get(key)
        }

    safe_sources: list[dict[str, str]] = []
    sources = payload.get("sources")
    if isinstance(sources, list):
        for source in sources[:3]:
            if not isinstance(source, dict):
                continue
            safe_source = {
                key: str(source[key])
                for key in ("title", "checked_at", "baseline")
                if source.get(key)
            }
            if safe_source:
                safe_sources.append(safe_source)
    if safe_sources:
        result["sources"] = safe_sources

    proposed_actions = payload.get("proposed_actions")
    if isinstance(proposed_actions, list) and proposed_actions:
        result["native_action_requires_app_confirmation"] = True
        result["safety_note"] = (
            "Do not claim this action ran. Ask the user to review it in the "
            "CHECKPOINT Mac app."
        )

    return result


async def _query_local_helper(query: str) -> dict[str, Any]:
    normalized_query = " ".join(query.split())
    if not normalized_query:
        return {"status": "invalid_request", "message": "The query was empty."}
    if len(normalized_query) > MAX_QUERY_CHARACTERS:
        normalized_query = normalized_query[:MAX_QUERY_CHARACTERS]

    try:
        connection = _read_helper_connection()
        timeout = httpx.Timeout(10.0, connect=1.0)
        async with httpx.AsyncClient(timeout=timeout, trust_env=False) as client:
            response = await client.post(
                f"{connection.base_url}/turn",
                headers={"Authorization": f"Bearer {connection.token}"},
                json={"text": normalized_query, "modality": "voice"},
            )
            response.raise_for_status()
            return _spoken_result(response.json())
    except HelperConnectionError as error:
        return {"status": "unavailable", "message": str(error)}
    except (httpx.HTTPError, json.JSONDecodeError, ValueError):
        return {
            "status": "unavailable",
            "message": "The local CHECKPOINT helper did not answer. Open the Mac app and try again.",
        }


def _create_server() -> tuple[Any, Any]:
    # LiveKit is an optional runtime dependency. Keeping imports here lets the
    # local helper and its tests run even when the voice extra is not installed.
    from livekit.agents import (
        Agent,
        AgentServer,
        AgentSession,
        JobContext,
        RunContext,
        cli,
        inference,
    )
    from livekit.agents.llm import function_tool

    class CheckpointVoiceAgent(Agent):
        def __init__(self) -> None:
            super().__init__(
                instructions=(
                    "You are CHECKPOINT, a concise voice interface to the user's saved "
                    "local work sessions. Speak plainly and keep responses short. Use "
                    "search_checkpoint_memory whenever the user asks about prior work, "
                    "a saved checkpoint, or resuming something. The tool is read-only. "
                    "You cannot open apps or files, change the Mac, save or delete data, "
                    "or approve a proposed action. If the tool says an action requires "
                    "app confirmation, tell the user to review it in the CHECKPOINT Mac "
                    "app and never imply that it already ran. Do not speak markdown, "
                    "internal identifiers, credentials, or local file paths."
                )
            )

        async def on_enter(self) -> None:
            self.session.generate_reply(
                instructions="Greet the user in one short sentence and ask what they want to resume."
            )

        @function_tool
        async def search_checkpoint_memory(
            self, context: RunContext, query: str
        ) -> str:
            """Search the user's local CHECKPOINT memory without changing the Mac.

            Use this for questions about saved work, remembered context, or resuming a
            previous task. This only retrieves information. It cannot execute or
            approve any action.

            Args:
                query: The user's complete memory-search request in plain language.
            """

            del context
            result = await _query_local_helper(query)
            return json.dumps(result, ensure_ascii=False, separators=(",", ":"))

    server = AgentServer()
    agent_name = _env_or_default("LIVEKIT_AGENT_NAME", DEFAULT_AGENT_NAME)

    @server.rtc_session(agent_name=agent_name)
    async def entrypoint(ctx: JobContext) -> None:
        ctx.log_context_fields = {"room": ctx.room.name, "agent": agent_name}
        session = AgentSession(
            stt=inference.STT(
                model=_env_or_default("LIVEKIT_INFERENCE_STT_MODEL", DEFAULT_STT_MODEL),
                language=_env_or_default(
                    "LIVEKIT_INFERENCE_LANGUAGE", DEFAULT_LANGUAGE
                ),
            ),
            llm=inference.LLM(
                model=_env_or_default("LIVEKIT_INFERENCE_LLM_MODEL", DEFAULT_LLM_MODEL),
                extra_kwargs={"temperature": 0.2},
            ),
            tts=inference.TTS(
                model=_env_or_default("LIVEKIT_INFERENCE_TTS_MODEL", DEFAULT_TTS_MODEL),
                voice=_env_or_default("LIVEKIT_INFERENCE_TTS_VOICE", DEFAULT_TTS_VOICE),
                language=_env_or_default(
                    "LIVEKIT_INFERENCE_LANGUAGE", DEFAULT_LANGUAGE
                ),
            ),
        )
        await session.start(agent=CheckpointVoiceAgent(), room=ctx.room)

    return server, cli


try:
    server, _livekit_cli = _create_server()
    _livekit_import_error: ModuleNotFoundError | None = None
except ModuleNotFoundError as error:
    # The rest of checkpoint_agent remains importable without the optional
    # LiveKit packages. Running this module still produces a useful error.
    server = None
    _livekit_cli = None
    _livekit_import_error = error


def main() -> None:
    if server is None or _livekit_cli is None:
        missing = _livekit_import_error.name if _livekit_import_error else "LiveKit"
        raise SystemExit(
            "CHECKPOINT voice dependencies are unavailable "
            f"(missing {missing}). Install livekit-agents 1.6.6 and the matching "
            "voice extra before running the voice worker."
        )
    _livekit_cli.run_app(server)


if __name__ == "__main__":
    main()
