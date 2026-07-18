from __future__ import annotations

import os
from typing import Protocol

from .schemas import CheckpointRecord, UserTurn


class Planner(Protocol):
    name: str
    available: bool

    async def answer(self, turn: UserTurn, context: list[CheckpointRecord]) -> str: ...


class DeterministicPlanner:
    name = "deterministic"
    available = True

    async def answer(self, turn: UserTurn, context: list[CheckpointRecord]) -> str:
        if context:
            return f"I found {len(context)} local checkpoint match{'es' if len(context) != 1 else ''}."
        return "I couldn't find that in your local checkpoints. Try a title, blocker, app, file, or URL."


class OpenAIPlanner:
    """Optional reasoning layer; native actions are never accepted from this class."""

    name = "openai"
    available = True

    def __init__(self, client: object, model: str) -> None:
        self._client = client
        self._model = model

    @classmethod
    def from_environment(cls) -> Planner:
        api_key = os.getenv("OPENAI_API_KEY")
        if not api_key:
            return DeterministicPlanner()
        return cls.from_api_key(api_key, os.getenv("OPENAI_MODEL", "gpt-5.4-mini"))

    @classmethod
    def from_api_key(cls, api_key: str, model: str = "gpt-5.4-mini") -> Planner:
        try:
            from openai import AsyncOpenAI

            return cls(AsyncOpenAI(api_key=api_key), model)
        except Exception:
            return DeterministicPlanner()

    async def answer(self, turn: UserTurn, context: list[CheckpointRecord]) -> str:
        compact_context = [
            {
                "title": checkpoint.title,
                "summary": checkpoint.summary,
                "next_step": checkpoint.next_step,
            }
            for checkpoint in context[:3]
        ]
        response = await self._client.responses.create(
            model=self._model,
            instructions=(
                "You are CHECKPOINT, a concise local work-memory assistant. "
                "Use only the supplied checkpoint summaries. If they do not answer "
                "the request, say so. Never propose shell commands or claim an action ran."
            ),
            input=f"Request: {turn.text}\nLocal checkpoint summaries: {compact_context}",
            store=False,
        )
        return response.output_text.strip()
