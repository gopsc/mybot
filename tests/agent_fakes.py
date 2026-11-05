"""Scripted LangChain chat models for tests.

The old suite used PydanticAI's FunctionModel and message parts. This module
keeps the same authoring style while producing LangChain messages, so tests can
drive the LangGraph agent without network access.
"""
from __future__ import annotations

from dataclasses import dataclass
import base64
import inspect
import json
from types import SimpleNamespace
from typing import Any

from langchain_core.language_models.chat_models import BaseChatModel
from langchain_core.messages import AIMessage, AIMessageChunk, HumanMessage, SystemMessage, ToolMessage
from langchain_core.outputs import ChatGeneration, ChatGenerationChunk, ChatResult
from pydantic import ConfigDict

from pymybot.agent import AgentBudgetExceeded


@dataclass
class TextPart:
    content: str


@dataclass
class ToolCallPart:
    tool_name: str
    args: dict[str, Any]
    tool_call_id: str = "call"


@dataclass
class ToolReturnPart:
    tool_name: str
    content: Any
    tool_call_id: str = ""


@dataclass
class UserPromptPart:
    content: str


@dataclass
class ImagePart:
    data: bytes
    media_type: str


@dataclass
class DeltaToolCall:
    name: str
    json_args: str
    tool_call_id: str = "call"
    index: int = 0


class ModelResponse:
    def __init__(self, parts):
        self.parts = list(parts)


UsageLimitExceeded = AgentBudgetExceeded
models = SimpleNamespace(ALLOW_MODEL_REQUESTS=True)


def _text(content):
    if isinstance(content, str):
        return content
    parts = []
    for block in content or []:
        if isinstance(block, str):
            parts.append(block)
        elif isinstance(block, dict) and block.get("type") == "text":
            parts.append(str(block.get("text", "")))
    return "".join(parts)


class _Message:
    def __init__(self, parts):
        self.parts = list(parts)


def _parts(messages):
    wrapper = []
    for message in messages:
        parts = []
        if isinstance(message, HumanMessage):
            parts.append(UserPromptPart(_text(message.content)))
        elif isinstance(message, ToolMessage):
            parts.append(ToolReturnPart(message.name or "", _tool_content(message.content),
                                        message.tool_call_id or ""))
            images = []
            if isinstance(message.content, list):
                for block in message.content:
                    if isinstance(block, dict) and block.get("type") == "image":
                        try:
                            data = base64.b64decode(block.get("base64", ""))
                        except (ValueError, TypeError):
                            continue
                        images.append(ImagePart(data, block.get("mime_type", "")))
            if images:
                wrapper.append(_Message([UserPromptPart(images)]))
        elif isinstance(message, AIMessage):
            text = _text(message.content)
            if text:
                parts.append(TextPart(text))
            for call in message.tool_calls:
                parts.append(ToolCallPart(call.get("name", ""), call.get("args") or {},
                                          call.get("id", "call")))
        if parts:
            wrapper.append(_Message(parts))
    return wrapper


def _tool_content(content):
    text = _text(content)
    try:
        return json.loads(text)
    except (TypeError, ValueError):
        return text


class _ToolInfo:
    def __init__(self, name):
        self.name = name


class _Info:
    def __init__(self, tools, instructions=""):
        self.function_tools = [_ToolInfo(tool.name) for tool in tools]
        self.instructions = instructions


def _instructions(messages):
    return "\n".join(_text(message.content) for message in messages
                     if isinstance(message, SystemMessage))


def _response_message(response):
    content, calls = [], []
    for part in response.parts:
        if isinstance(part, TextPart):
            content.append(part.content)
        elif isinstance(part, ToolCallPart):
            calls.append({"name": part.tool_name, "args": part.args, "id": part.tool_call_id})
        elif isinstance(part, DeltaToolCall):
            calls.append({"name": part.name, "args": json.loads(part.json_args or "{}"),
                          "id": part.tool_call_id})
    return AIMessage(content="".join(content), tool_calls=calls,
                     usage_metadata={"input_tokens": 10, "output_tokens": 5, "total_tokens": 15})


class FunctionModel(BaseChatModel):
    """Minimal scripted chat model: ``respond(messages, info) -> ModelResponse``."""

    model_config = ConfigDict(arbitrary_types_allowed=True)
    respond: Any
    stream_function: Any = None
    bound: tuple = ()

    def __init__(self, respond=None, stream_function=None, **kwargs):
        super().__init__(respond=respond, stream_function=stream_function, **kwargs)

    @property
    def _llm_type(self):
        return "scripted"

    def bind_tools(self, tools, **kwargs):
        self.bound = tuple(tools)
        return self

    async def _invoke_respond(self, messages):
        value = self.respond(_parts(messages), _Info(self.bound, _instructions(messages)))
        if inspect.isawaitable(value):
            value = await value
        return value

    def _generate(self, messages, stop=None, run_manager=None, **kwargs):
        try:
            value = self.respond(_parts(messages), _Info(self.bound, _instructions(messages)))
        except TypeError:
            value = self.respond(_parts(messages), _Info(self.bound, _instructions(messages)))
        if inspect.isawaitable(value):
            raise RuntimeError("Use the async agent path for async respond functions")
        return ChatResult(generations=[ChatGeneration(message=_response_message(value))])

    async def _agenerate(self, messages, stop=None, run_manager=None, **kwargs):
        value = await self._invoke_respond(messages)
        return ChatResult(generations=[ChatGeneration(message=_response_message(value))])

    async def _astream(self, messages, stop=None, run_manager=None, **kwargs):
        if self.stream_function is not None:
            value = self.stream_function(_parts(messages), _Info(self.bound, _instructions(messages)))
            if inspect.isawaitable(value):
                value = await value
            next_index = 0
            async for part in value:
                if isinstance(part, str):
                    yield ChatGenerationChunk(message=AIMessageChunk(content=part))
                elif isinstance(part, TextPart):
                    yield ChatGenerationChunk(message=AIMessageChunk(content=part.content))
                elif isinstance(part, dict):
                    for item in part.values():
                        if isinstance(item, DeltaToolCall):
                            yield ChatGenerationChunk(message=AIMessageChunk(
                                content="", tool_call_chunks=[{
                                    "name": item.name, "args": item.json_args,
                                    "id": item.tool_call_id, "index": next_index}]))
                            next_index += 1
                elif isinstance(part, DeltaToolCall):
                    yield ChatGenerationChunk(message=AIMessageChunk(
                        content="", tool_call_chunks=[{
                            "name": part.name, "args": part.json_args,
                            "id": part.tool_call_id, "index": next_index}]))
                    next_index += 1
            return
        value = await self._invoke_respond(messages)
        message = _response_message(value)
        if message.tool_calls:
            yield ChatGenerationChunk(message=AIMessageChunk(
                content="", tool_call_chunks=[{
                    "name": call["name"], "args": json.dumps(call["args"], ensure_ascii=False),
                    "id": call["id"], "index": index}
                    for index, call in enumerate(message.tool_calls)]))
        if message.content:
            yield ChatGenerationChunk(message=AIMessageChunk(
                content=message.content,
                usage_metadata=message.usage_metadata))


class TestModel(FunctionModel):
    """Fixed text response, matching the old TestModel(custom_output_text=...)."""

    def __init__(self, custom_output_text="done", **kwargs):
        super().__init__(
            respond=lambda messages, info: ModelResponse([TextPart(custom_output_text)]),
            **kwargs)


def text_model(text="done"):
    return TestModel(custom_output_text=text)



def _prompt_text(messages):
    return " ".join(str(part.content) for message in messages
                    for part in getattr(message, "parts", ())
                    if hasattr(part, "content"))


def _between(text, start, end):
    index = text.find(start)
    if index < 0:
        return ""
    index += len(start)
    stop = text.find(end, index)
    return (text[index:] if stop < 0 else text[index:stop]).strip()


def team_model(worker_model):
    """Wrap a scripted worker model so it also answers the memory protocol.

    The dual-agent team makes one memory call before the worker runs and one
    after; tests that only script worker turns still exercise the same worker
    behaviour through this adapter.
    """
    async def respond(messages, info):
        text = _prompt_text(messages)
        if "自拟下一个任务目标" in text:
            return ModelResponse(parts=[TextPart('{"goal":""}')])
        if "任务目标：" in text and "长期记忆" in text:
            goal = _between(text, "任务目标：", "\n\n第")
            report = _between(text, "执行体最近一次回报：", "\n\n请输出")
            if report.startswith("（尚无回报）"):
                payload = {"action": "continue", "brief": goal or "执行任务"}
            else:
                payload = {"action": "done", "summary": report or "完成"}
            return ModelResponse(parts=[TextPart(json.dumps(payload, ensure_ascii=False))])
        value = worker_model.respond(messages, info)
        if inspect.isawaitable(value):
            value = await value
        return value

    return FunctionModel(respond)
