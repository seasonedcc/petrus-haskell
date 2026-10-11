"""A fake ``claude_agent_sdk`` for the Haskell Claude sidecar tests.

It has the pinned SDK's public protocol surface (the attributes and
``ClaudeAgentOptions`` fields upstream's probe requires) and a
``ClaudeSDKClient`` that exercises everything the adapter hands the SDK:
the PreToolUse hook (one foreign tool, one workspace read), the in-process
MCP tool handler, and the session store (``load`` on resume, ``append`` of
the turn's main transcript). The prompt selects a script:

* ``block``: yield ``system/init`` and wait for ``interrupt``.
* ``unclean``: leave the fake child running after ``disconnect``.
* anything else: complete with a ``success`` result.
"""

import asyncio
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from types import SimpleNamespace

SESSION = "11111111-1111-4111-8111-111111111111"
PROJECT_KEY = "-tmp-agenticus-claude-project"


@dataclass
class SystemMessage:
    subtype: str
    data: dict = field(default_factory=dict)


@dataclass
class UserMessage:
    content: str


@dataclass
class AssistantMessage:
    content: list
    model: str = "fake"


@dataclass
class ResultMessage:
    subtype: str
    is_error: bool
    session_id: str
    terminal_reason: str | None
    result: str | None
    num_turns: int = 1


@dataclass
class MirrorErrorMessage:
    error: str


@dataclass
class StreamEvent:
    event: dict


@dataclass
class RateLimitEvent:
    status: str


@dataclass
class HookMatcher:
    matcher: str | None = None
    hooks: list = field(default_factory=list)


@dataclass
class SdkMcpTool:
    name: str
    description: str
    input_schema: dict
    handler: object


class SessionStore:
    pass


def tool(name, description, input_schema):
    def wrap(handler):
        return SdkMcpTool(name, description, input_schema, handler)

    return wrap


def create_sdk_mcp_server(name, version="1.0.0", tools=None):
    return {"type": "sdk", "name": name, "version": version, "tools": list(tools or [])}


@dataclass
class ClaudeAgentOptions:
    tools: object = None
    allowed_tools: object = None
    mcp_servers: object = None
    strict_mcp_config: object = None
    permission_mode: object = None
    resume: object = None
    session_store: object = None
    session_store_flush: object = None
    setting_sources: object = None
    skills: object = None
    plugins: object = None
    agents: object = None
    model: object = None
    fallback_model: object = None
    cwd: object = None
    cli_path: object = None
    env: object = None
    max_turns: object = None
    max_budget_usd: object = None
    max_buffer_size: object = None
    hooks: object = None
    stderr: object = None


class ClaudeSDKClient:
    def __init__(self, options):
        self.options = options
        self.loaded = []
        self.prompt = None
        self._interrupted = asyncio.Event()

    async def connect(self, prompt=None):
        assert prompt is None
        if self.options.resume is not None:
            key = {"project_key": PROJECT_KEY, "session_id": self.options.resume}
            self.loaded = await self.options.session_store.load(key) or []
        self._materialized = SimpleNamespace(config_dir=Path(tempfile.mkdtemp(prefix="fake-claude-")))
        self._transport = SimpleNamespace(_process=SimpleNamespace(returncode=None))

    async def query(self, prompt, session_id="default"):
        assert session_id == "default"
        self.prompt = prompt

    async def receive_response(self):
        yield SystemMessage("init", {"cwd": str(self.options.cwd)})
        if self.prompt == "block":
            await self._interrupted.wait()
            return
        hook = self.options.hooks["PreToolUse"][0].hooks[0]
        denied = await hook({"tool_name": "Read", "tool_use_id": "toolu_foreign", "tool_input": {"path": "x"}}, None, {})
        assert denied["hookSpecificOutput"]["permissionDecision"] == "deny"
        arguments = {"path": "marker.txt"}
        allowed = await hook(
            {"tool_name": "mcp__petrus_hands__workspace_read", "tool_use_id": "toolu_read", "tool_input": arguments},
            None,
            {},
        )
        assert allowed["hookSpecificOutput"]["permissionDecision"] == "allow"
        server = self.options.mcp_servers["petrus_hands"]
        read = next(item for item in server["tools"] if item.name == "workspace_read")
        response = await read.handler(dict(arguments))
        text = response["content"][0]["text"]
        n = len(self.loaded)
        await self.options.session_store.append(
            {"project_key": PROJECT_KEY, "session_id": SESSION},
            [
                {"type": "user", "uuid": f"user-{n}", "message": self.prompt},
                {"type": "assistant", "uuid": f"assistant-{n}", "message": text},
            ],
        )
        yield AssistantMessage([{"type": "text", "text": text}])
        yield ResultMessage("success", bool(response.get("is_error")), SESSION, "completed", "read:" + text)

    async def interrupt(self):
        self._interrupted.set()

    async def disconnect(self):
        self._interrupted.set()
        if self.prompt != "unclean":
            self._transport._process.returncode = 0
        materialized = getattr(self, "_materialized", None)
        if materialized is not None and materialized.config_dir.exists():
            materialized.config_dir.rmdir()
