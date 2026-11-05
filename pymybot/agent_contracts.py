"""Strict schemas for the planner side of the agent team.

Provider-native structured output is preferred; plain JSON text remains a
documented fallback for models that do not implement it.
"""
from __future__ import annotations

from typing import Literal
from pydantic import BaseModel, Field

MEMORY_KINDS = ("fact", "decision", "preference", "gotcha", "summary", "task")


class MemoryProposal(BaseModel):
    text: str = Field(min_length=1, max_length=2000)
    kind: Literal["fact", "decision", "preference", "gotcha", "summary", "task"] = "fact"
    tags: list[str] = Field(default_factory=list, max_length=8)
    salience: float = Field(default=0.6, ge=0.0, le=1.0)


class PlanDecision(BaseModel):
    action: Literal["continue", "done", "blocked"]
    brief: str = Field(default="", max_length=8192)
    reasoning: str = Field(default="", max_length=1000)
    summary: str = Field(default="", max_length=12 * 1024)
    memories: list[MemoryProposal] = Field(default_factory=list, max_length=8)
    next_goal: str = Field(default="", max_length=16 * 1024)


class GoalProposal(BaseModel):
    goal: str = Field(default="", max_length=16 * 1024)
    reason: str = Field(default="", max_length=1000)
