#!/usr/bin/env python3
"""离线假 OpenAI 兼容服务（仅用于 agent 模式守门，不参与构建产物）。

按「已经回传了几条 tool 消息」推进剧本，用来验证 agent 工具循环真的迭代了、
且工具结果真的回传给了模型：
    0 条 → 调 list_hardware
    1 条 → 调 run_action_script(relay-test.mt)
    2 条 → 调 run_command(echo agent-echo-ok)
    ≥3 条 → 给出最终回答

响应里带 reasoning_content：这样 DeepSeek 驱动必须把它回传到下一轮请求，
守门脚本才能在抓到的报文里断言这条有状态协议要求确实生效。

用法: python3 scripts/fake_llm_server.py <port> [capture_file] [mode] [headers_file]
      mode: ok（默认） | slow（睡 5 秒再答，用于验证 --llm-timeout 真的生效）
            | camera（先要求拍一张照片，再给最终回答——验证图片真的进了上下文）
            | hotsql（先要求 apply_sql 往既有表 INSERT 一行，再列硬件——验证结构
              SQL 真的带电生效；缺 --agent-hot-sql 时同一条剧本只剩「未知工具」）
            | hotdelete（先插一行临时的、再 DELETE 掉它、然后列硬件——验证热删除
              真的把变量摘掉了；与 hotsql 同门控）
            | readvars（先要求 read_variables 读回可读变量——验证回读通道真的
              把驱动返回表带进回执；缺 --read-var 时同一条剧本只剩「未知工具」）
            | httpfetch（按环境变量 FAKE_LLM_FETCH_URLS 逗号分隔的 URL 逐轮下发
              http_fetch，发完给最终回答——Phase 6 Rust 本地工具的端到端）
            | manycalls[:N]（首轮返回 N 条工具调用，缺省 3；配合
              max_calls_per_round=2 触发宿主的单轮截断分支——SAN-1）
            | 429x2ok（前两次 429 + Retry-After: 1，第三次正常回答——SAN-3：
              不重试则只收到 1 个 POST 且任务失败，重试则 3 个 POST 且成功）
            | http-503（恒 503 + Retry-After: 1——SAN-3：重试用尽后如实失败）
            | relay（批次 D，R11 两进程接力）：请求历史里一旦出现上一个进程的
              收尾文案 "AGENT-E2E-完成"（--resume 把它带回来了），立即给一句
              专属回答 "AGENT-E2E-RELAY-完成"（不再走完整工具循环）；否则与
              默认剧本同构（新会话，从头走 list_hardware → 动作 → 命令 → 收尾）
      headers_file: 非空则把收到的请求头逐行写入（用来断言 API key 的来源）

流式（2026-09-25，Rust agent 流式输出）：请求体带 "stream": true 时，同一份剧本
应答改以 SSE 发出——OpenAI 系发 chat.completion.chunk 逐 delta 帧（content /
reasoning_content / tool_calls 按 index 拼装）+ 末尾 usage 帧 + `data: [DONE]`；
Anthropic 发 message_start → content_block_* → message_delta（usage）→ message_stop。
文本会被拆成多帧；环境变量 FAKE_LLM_FRAME_DELAY_MS（缺省 0）给帧间加停顿，
E2E 用它证明「第一个字节确实先于最后一个字节到达 stdout」。剧本、校验与错误
模式（400/429/503/slow）不因流式与否而变——错误仍是整块 JSON + 非 200 状态码。
"""
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1])
CAPTURE = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else None
MODE = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else "ok"
HEADERS = sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] else None
FRAME_DELAY = int(os.environ.get("FAKE_LLM_FRAME_DELAY_MS", "0")) / 1000.0
# 文本拆帧粒度（字符数）：小到一句收尾文案能拆出好几帧，大到帧数不至于失控
TEXT_PIECE = 6

# 跨请求计数（429x2ok 用它决定第几次请求开始放行）。服务是单进程单线程
# （HTTPServer 非 ThreadingHTTPServer），无并发，故不需要锁。
ATTEMPTS = {"n": 0}


def openai_shell(payload):
    """补上 OpenAI 形态应答的外壳字段 id/model。

    2026-09-24（rig 迁移）：rig 0.42 的 CompletionResponse 把 id 与 model 定为
    **必填**（缺任一即 ProviderResponseError），而真网关的应答也都带这两项——
    夹具此前省略它们，只有 C++ 驱动（只取 choices）不介意。补上后同一份夹具对
    两份实现都成立；C++ 侧忽略多余字段，故不影响既有场景。
    """
    payload.setdefault("id", "chatcmpl-fake")
    payload.setdefault("model", "fake-model")
    payload.setdefault("usage", {"prompt_tokens": 111, "completion_tokens": 22,
                                 "total_tokens": 133})
    for i, choice in enumerate(payload.get("choices", [])):
        choice.setdefault("index", i)
        choice.setdefault("finish_reason", "tool_calls" if choice["message"].get("tool_calls") else "stop")
    return payload


def tool_call(name, arguments, call_id=None):
    return openai_shell({
        "choices": [{
            "message": {
                "role": "assistant",
                "content": None if MODE.startswith("deepseek") else "调用工具 %s。" % name,
                "reasoning_content": "先想清楚再决定调用 %s。" % name,
                "tool_calls": [{
                    "id": call_id or "call_%s" % name,
                    "type": "function",
                    "function": {"name": name, "arguments": json.dumps(arguments)},
                }],
            }
        }]
    })


def anthropic_tool_call(name, arguments):
    """Anthropic Messages 形态的一轮工具调用应答（批次 3）。

    与 OpenAI 系的差别正是驱动要抹平的那些：content 是**块数组**、
    工具调用是 tool_use 块（input 是对象）、没有 choices 外壳。
    """
    return {
        "id": "msg_fake_tool", "type": "message", "role": "assistant", "model": "fake-model",
        "content": [
            {"type": "text", "text": "调用工具 %s。" % name},
            {"type": "tool_use", "id": "toolu_%s" % name, "name": name,
             "input": arguments},
        ],
        "stop_reason": "tool_use",
        "usage": {"input_tokens": 111, "output_tokens": 22},
    }


def anthropic_final_answer(text="AGENT-E2E-完成：已查看硬件、执行动作并拍照。"):
    return {
        "id": "msg_fake_final", "type": "message", "role": "assistant", "model": "fake-model",
        "content": [
            {"type": "text", "text": text},
        ],
        "stop_reason": "end_turn",
        "usage": {"input_tokens": 1234, "output_tokens": 56},
    }


def final_answer():
    # SAN-9：带上 provider 的 usage——宿主的审计模型记录要挑 prompt_tokens /
    # completion_tokens 记账（只记 provider 给的数，不推算）。真机也这么返回。
    return openai_shell({
        "choices": [{
            "message": {
                "role": "assistant",
                "content": "AGENT-E2E-完成：已查看硬件，继电器动作已执行，命令已运行。",
                "reasoning_content": "收尾。",
            }
        }],
        "usage": {"prompt_tokens": 1234, "completion_tokens": 56, "total_tokens": 1290},
    })


def split_text(text):
    """把一段文本拆成多个 delta（空文本 → 无帧）。"""
    return [text[i:i + TEXT_PIECE] for i in range(0, len(text), TEXT_PIECE)]


def openai_sse_frames(payload):
    """把一份完整的 chat.completion 应答改写成 chat.completion.chunk 帧序列。

    形态按真网关：首帧只带 role；reasoning_content / content 逐段；tool_calls 第一帧
    带 id+name+空 arguments、其后按 index 只补 arguments 片段；finish_reason 单独一帧；
    最后一帧 choices 为空、只带 usage（stream_options.include_usage 的形态）。
    """
    choice = payload["choices"][0]
    msg = choice["message"]
    base = {"id": payload["id"], "object": "chat.completion.chunk",
            "created": 0, "model": payload["model"]}

    def chunk(delta, finish=None):
        c = dict(base)
        c["choices"] = [{"index": 0, "delta": delta, "finish_reason": finish}]
        return c

    frames = [chunk({"role": "assistant", "content": ""})]
    if msg.get("reasoning_content"):
        for piece in split_text(msg["reasoning_content"]):
            frames.append(chunk({"reasoning_content": piece}))
    for piece in split_text(msg.get("content") or ""):
        frames.append(chunk({"content": piece}))
    for i, tc in enumerate(msg.get("tool_calls") or []):
        frames.append(chunk({"tool_calls": [{
            "index": i, "id": tc["id"], "type": "function",
            "function": {"name": tc["function"]["name"], "arguments": ""},
        }]}))
        for piece in split_text(tc["function"]["arguments"]):
            frames.append(chunk({"tool_calls": [{"index": i, "function": {"arguments": piece}}]}))
    frames.append(chunk({}, finish=choice["finish_reason"]))
    tail = dict(base)
    tail["choices"] = []
    tail["usage"] = payload["usage"]
    frames.append(tail)
    return [(None, f) for f in frames] + [(None, "[DONE]")]


def anthropic_sse_frames(payload):
    """把一份完整的 Anthropic message 改写成 message_start/…/message_stop 事件序列。"""
    usage = payload["usage"]
    frames = [("message_start", {"type": "message_start", "message": {
        "id": payload["id"], "type": "message", "role": "assistant", "content": [],
        "model": payload["model"], "stop_reason": None, "stop_sequence": None,
        "usage": {"input_tokens": usage["input_tokens"], "output_tokens": 1},
    }})]
    for i, block in enumerate(payload["content"]):
        if block["type"] == "text":
            frames.append(("content_block_start", {
                "type": "content_block_start", "index": i,
                "content_block": {"type": "text", "text": ""}}))
            for piece in split_text(block["text"]):
                frames.append(("content_block_delta", {
                    "type": "content_block_delta", "index": i,
                    "delta": {"type": "text_delta", "text": piece}}))
        else:
            frames.append(("content_block_start", {
                "type": "content_block_start", "index": i,
                "content_block": {"type": "tool_use", "id": block["id"],
                                  "name": block["name"], "input": {}}}))
            for piece in split_text(json.dumps(block["input"])):
                frames.append(("content_block_delta", {
                    "type": "content_block_delta", "index": i,
                    "delta": {"type": "input_json_delta", "partial_json": piece}}))
        frames.append(("content_block_stop", {"type": "content_block_stop", "index": i}))
    frames.append(("message_delta", {
        "type": "message_delta",
        "delta": {"stop_reason": payload["stop_reason"], "stop_sequence": None},
        "usage": {"output_tokens": usage["output_tokens"]}}))
    frames.append(("message_stop", {"type": "message_stop"}))
    return frames


def protocol_error(request):
    """像真机一样校验「有状态协议」，返回错误消息或 None（2026-09-21 审计 AG-1/AG-7）。

    存在的意义与 schema_error 相同：夹具比真机宽松，缺陷就会一路溜到真机才暴露。
    此前这里只校验 schema，于是下面三类「真机必然 400」的报文在离线守门里全绿：

      ① 请求体不是合法 UTF-8 —— 历史里任何一条消息带上非法字节（run_command 输出
         二进制、非 UTF-8 日志、脚本首注释、结构脚本头）都会命中。真网关 400 之后
         那条消息已落在不可回滚的历史里，会话从此每次都以同一字节偏移失败。
         此前 `except ValueError` 顺手把 UnicodeDecodeError 也吞了 → 请求被判成 {}
         后照常 200，**结构上不可能报出这个失败**。
      ② reasoning_content 有状态要求 —— 请求里一旦出现该字段（DeepSeek 思考模式），
         每条带 tool_calls 的历史 assistant 都必须带上它，缺一条真机直接 400。
         用「请求中出现过」作开关而不是无条件要求：OpenAI 兼容驱动压根不认识这个
         字段，无条件要求会把合法请求判死。
      ③ tool_call_id 必须与 assistant.tool_calls 一一配对 —— 孤儿 tool 消息、
         重复回传、或漏回传某个 tool_call，真机都是 400。**id 还得非空**：
         空 id 配不上任何声明，真机同样 400（Rust 产线判据
         `agent/src/session.rs::protocol_violation` 也拒空 id；两侧规则集由
         `scripts/check_stateful_protocol.py` 零编译互钉）。
    """
    messages = request.get("messages")
    if not isinstance(messages, list):
        return "messages must be an array"

    # ① 非法 UTF-8 由调用方在解码阶段拦下（这里只兜「已解码但含代理项」的极端情况）
    for i, m in enumerate(messages):
        if not isinstance(m, dict):
            return "messages[%d] must be an object" % i

    if MODE.startswith("anthropic"):
        return anthropic_protocol_error(request)
    if MODE.startswith("deepseek") and any(not isinstance(m.get("content"), str) for m in messages):
        return "DeepSeek requires string content, including tool-call-only assistant messages"

    # 模式显式要求回传，避免所有 reasoning_content 都丢失时校验被绕过。
    uses_reasoning = MODE.startswith("deepseek") or any(
        isinstance(m.get("reasoning_content"), str) for m in messages)
    if uses_reasoning:
        for i, m in enumerate(messages):
            if m.get("role") != "assistant":
                continue
            if m.get("tool_calls") and not isinstance(m.get("reasoning_content"), str):
                return ("messages[%d]: assistant message with tool_calls is missing "
                        "reasoning_content (DeepSeek requires it in thinking mode)" % i)

    # ③ tool_call_id 配对
    declared = []          # assistant 声明的 tool_call id，按出现顺序
    for m in messages:
        if m.get("role") != "assistant":
            continue
        tcs = m.get("tool_calls")
        if tcs is None:
            continue
        if not isinstance(tcs, list):
            return "assistant.tool_calls must be an array"
        for tc in tcs:
            if not isinstance(tc, dict) or not isinstance(tc.get("id"), str):
                return "assistant.tool_calls[].id must be a string"
            if not tc["id"]:
                return "assistant.tool_calls[].id must be a non-empty string"
            declared.append(tc["id"])

    answered = []
    for i, m in enumerate(messages):
        if m.get("role") != "tool":
            continue
        tcid = m.get("tool_call_id")
        if not isinstance(tcid, str):
            return "messages[%d]: tool message requires a string tool_call_id" % i
        if not tcid:
            return "messages[%d]: tool message has an empty tool_call_id" % i
        if tcid not in declared:
            return ("messages[%d]: tool_call_id %r does not match any assistant "
                    "tool_call" % (i, tcid))
        if tcid in answered:
            return "messages[%d]: tool_call_id %r answered more than once" % (i, tcid)
        answered.append(tcid)
    missing = [c for c in declared if c not in answered]
    if missing:
        return "assistant.tool_calls %r got no matching tool message" % (missing,)
    return None


def schema_error(request):
    """像 DeepSeek 一样严格校验工具 schema，返回错误消息或 None。

    真实 API 会拒绝不合法的 schema（照抄它的原话：
    `Invalid schema for function 'x': {} is not of type "array"`）。
    夹具若不校验，这类 bug 就会一路溜到真机才暴露——本函数存在的意义就是
    把真机的校验前移到离线守门里。
    """
    for t in request.get("tools", []):
        # 形状分派（批次 3）：OpenAI 系把声明包在 function 里（parameters），
        # Anthropic 是扁平的 name/input_schema。夹具按请求自身的形状选判据——
        # 判据本身仍与真机一样严，只是不再用一种协议的尺子量另一种协议的报文。
        if t.get("function") is None and "input_schema" in t:
            name = t.get("name")
            schema = t.get("input_schema")
            if not isinstance(schema, dict):
                return ("Invalid schema for tool '%s': input_schema must be an object"
                        % name)
            if schema.get("type") != "object":
                return ('Invalid schema for tool \'%s\': type must be "object"' % name)
            req = schema.get("required")
            if req is not None and not isinstance(req, list):
                return ('Invalid schema for tool \'%s\': %s is not of type "array"'
                        % (name, json.dumps(req)))
            props = schema.get("properties")
            if props is not None and not isinstance(props, dict):
                return ('Invalid schema for tool \'%s\': properties is not of type "object"'
                        % name)
            continue
        fn = t.get("function") or {}
        name = fn.get("name")
        params = fn.get("parameters")
        if not isinstance(params, dict):
            return "Invalid schema for function '%s': parameters must be an object" % name
        if params.get("type") != "object":
            return "Invalid schema for function '%s': type must be \"object\"" % name
        req = params.get("required")
        if req is not None and not isinstance(req, list):
            return ('Invalid schema for function \'%s\': %s is not of type "array"'
                    % (name, json.dumps(req)))
        props = params.get("properties")
        if props is not None and not isinstance(props, dict):
            return ('Invalid schema for function \'%s\': properties is not of type "object"'
                    % name)
    return None


def anthropic_protocol_error(request):
    if not request.get("system") or not isinstance(request.get("max_tokens"), int):
        return "Anthropic requires top-level system and max_tokens"
    for tool in request.get("tools", []):
        if not tool.get("name") or "input_schema" not in tool or "function" in tool:
            return "Anthropic tools require name/input_schema, not function"
    pending, declared = set(), set()
    for message in request["messages"]:
        role = message.get("role")
        if role not in ("user", "assistant") or "tool_calls" in message:
            return "Anthropic messages require user/assistant content blocks"
        content = message.get("content", [])
        if isinstance(content, str):
            content = [{"type": "text", "text": content}]
        if not isinstance(content, list) or any(not isinstance(b, dict) for b in content):
            return "Anthropic content must be text or an array of blocks"
        if pending:
            ids = [b.get("tool_use_id") for b in content if b.get("type") == "tool_result"]
            if role != "user" or set(ids) != pending or len(ids) != len(pending):
                return "Anthropic tool_use must be followed by matching tool_result blocks"
        for block in content:
            kind = block.get("type")
            if kind == "tool_use":
                tid = block.get("id")
                if role != "assistant" or not isinstance(tid, str) or not tid or tid in declared:
                    return "Anthropic tool_use id must be unique and on assistant"
                if not block.get("name") or not isinstance(block.get("input"), dict):
                    return "Anthropic tool_use requires name and object input"
                declared.add(tid)
                pending.add(tid)
            elif kind == "tool_result":
                tid = block.get("tool_use_id")
                if role != "user" or tid not in pending:
                    return "Anthropic orphan or duplicate tool_result"
                pending.remove(tid)
            elif kind == "image":
                source = block.get("source", {})
                if role != "user" or source.get("type") != "base64" or source.get("media_type") != "image/jpeg":
                    return "Anthropic fixture requires a base64 JPEG image source"
                if not isinstance(source.get("data"), str) or not source["data"].startswith("/9j/"):
                    return "Anthropic image data must contain the JPEG bytes, not a data URL"
            elif kind != "text":
                return "unexpected Anthropic content block: %s" % kind
    if pending:
        return "Anthropic missing tool_result"
    return None


def closed_loop_reply(request):
    results = [m for m in request["messages"] if m.get("role") == "tool"]
    expected_ids = ["call_read_before", "call_set_dac", "call_read_after"]
    if [m.get("tool_call_id") for m in results] != expected_ids[:len(results)]:
        raise ValueError("closed-loop: unexpected tool result order")
    if not results:
        return tool_call("read_variables", {}, expected_ids[0])

    def level(message):
        body = message["content"]
        marker = "  dac0 = "
        if not isinstance(body, str) or marker not in body:
            raise ValueError("closed-loop: missing dac0 readback")
        value, _ = json.JSONDecoder().raw_decode(body.split(marker, 1)[1])
        if value.get("result") != "OK" or value.get("rdy") != 1:
            raise ValueError("closed-loop: DAC readback failed or not ready")
        return value.get("level")

    if level(results[0]) != 0:
        raise ValueError("closed-loop: expected initial DAC level 0")
    if len(results) == 1:
        return tool_call("run_action_script", {"script": "test/mcp4725_virt.mt"}, expected_ids[1])
    if "已执行动作脚本 test/mcp4725_virt.mt" not in results[1].get("content", ""):
        raise ValueError("closed-loop: action did not succeed")
    if len(results) == 2:
        return tool_call("read_variables", {}, expected_ids[2])
    if level(results[2]) != 2048:
        raise ValueError("closed-loop: expected final DAC level 2048")
    return openai_shell({"choices": [{"message": {
        "role": "assistant", "content": "AGENT-E2E-CLOSED-LOOP-完成：已核验 DAC 0 → 2048。",
    }}]})


class Handler(BaseHTTPRequestHandler):
    # 本次请求是否要求流式（do_POST 一开始就从请求体里读出来）
    stream = False

    def _reply(self, payload):
        if self.stream:
            self._reply_sse(payload)
            return
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        try:
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass	# 客户端超时先走了：本服务是守门夹具，不必抱怨

    def _reply_sse(self, payload):
        """同一份剧本应答改以 SSE 发出；每帧 flush，帧间按 FRAME_DELAY 停顿。"""
        if payload.get("type") == "message":
            frames = anthropic_sse_frames(payload)
        else:
            frames = openai_sse_frames(payload)
        try:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            for n, (event, data) in enumerate(frames):
                if n and FRAME_DELAY > 0:
                    time.sleep(FRAME_DELAY)
                body = data if isinstance(data, str) else json.dumps(data, ensure_ascii=False)
                line = ("event: %s\n" % event if event else "") + "data: %s\n\n" % body
                self.wfile.write(line.encode("utf-8"))
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _error_400(self, message):
        data = json.dumps({"error": {"message": message, "type": "invalid_request_error"}},
                          ensure_ascii=False).encode("utf-8")
        try:
            self.send_response(400)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _error_status(self, code, message, retry_after=None, kind="server_error"):
        """带**非 200 状态码**的错误响应（SAN-3 的限流/5xx 场景用）。

        与 _error_400 分开的理由：400 是"请求错了，别再试"，而 429/503 是
        "稍后再试"——宿主的重试判据必须能区分这两类，夹具因此也要能产出两类。
        retry_after 非空时带上 Retry-After 响应头（SAN-3 要验证宿主读得到它）。"""
        data = json.dumps({"error": {"message": message, "type": kind}},
                          ensure_ascii=False).encode("utf-8")
        try:
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            if retry_after is not None:
                self.send_header("Retry-After", str(retry_after))
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(n) if n > 0 else b"{}"
        # 流式标志先于一切分支读出：slow 模式也要按请求要求的形态应答。
        # 这里解不出来不算错——严格的 UTF-8/JSON 校验在下面照常报 400。
        try:
            self.stream = json.loads(raw.decode("utf-8")).get("stream") is True
        except (ValueError, AttributeError):
            self.stream = False
        if CAPTURE:
            try:
                with open(CAPTURE, "wb") as f:
                    f.write(raw)
            except OSError:
                pass
        if HEADERS:
            try:
                with open(HEADERS, "w") as f:
                    for k, v in self.headers.items():
                        f.write("%s: %s\n" % (k, v))
            except OSError:
                pass
        if MODE == "slow":
            time.sleep(5)
            self._reply(openai_shell({"choices": [{"message": {"role": "assistant", "content": "慢响应"}}]}))
            return
        # 先做**严格 UTF-8 解码**（2026-09-21 审计 AG-1）。此前的 `except ValueError`
        # 把 UnicodeDecodeError（ValueError 的子类）一并吞掉，非法字节的请求被当成
        # `{}` 后照常 200——假网关于是比真网关宽松，AG-1 这类字节级缺陷在离线守门里
        # 结构上不可见。现在像真网关一样：解不出来就是 400，并点名首个坏字节位置。
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError as e:
            self._error_400("invalid utf-8 in request body: %s (byte 0x%02x at offset %d)"
                            % (e.reason, raw[e.start], e.start))
            return
        try:
            request = json.loads(text)
        except ValueError as e:
            self._error_400("invalid JSON in request body: %s" % e)
            return
        if MODE.startswith("anthropic"):
            if self.path != "/v1/messages" or self.headers.get("x-api-key") != "e2e-rust-key" or not self.headers.get("anthropic-version"):
                self._error_400("Anthropic requires /v1/messages, x-api-key and anthropic-version")
                return
        elif MODE.startswith("deepseek"):
            if self.path != "/v1/chat/completions" or self.headers.get("Authorization") != "Bearer e2e-rust-key":
                self._error_400("DeepSeek requires /v1/chat/completions and Bearer authorization")
                return
        for bad in (schema_error(request), protocol_error(request)):
            if bad is not None:
                self._error_400(bad)
                return
        if MODE == "closed-loop":
            try:
                self._reply(closed_loop_reply(request))
            except (ValueError, KeyError, TypeError) as e:
                self._error_400(str(e))
            return
        if MODE == "ica-flow":
            # First try an action without ICA preparation: the Rust agent must deny it.
            # Then inspect reality, register a prediction, execute, and compare.
            n = sum(1 for m in request.get("messages", []) if m.get("role") == "tool")
            if n == 0:
                reply = tool_call("run_action_script", {"script": "relay-test.mt"}, "ica_denied_action")
            elif n == 1:
                reply = tool_call("list_hardware", {})
            elif n == 2:
                reply = tool_call("ica_propose_action", {
                    "tool": "run_action_script",
                    "arguments": {"script": "relay-test.mt"},
                    "reason": "检查虚拟继电器动作",
                    "predicted_observation": "脚本执行成功并返回动作回执",
                })
            elif n == 3:
                reply = tool_call("run_action_script", {"script": "relay-test.mt"}, "ica_allowed_action")
            elif n == 4:
                reply = tool_call("ica_compare_future", {
                    "future_id": "F1", "event_id": "E3", "possible_match": True,
                })
            else:
                reply = openai_shell({"choices": [{"message": {
                    "role": "assistant", "content": "ICA-E2E-完成：先检查状态，再登记预测，执行并比较回执。"
                }}]})
            self._reply(reply)
            return
        # 工具结果的**计数**同样按形状分派（批次 3）：OpenAI 系是独立的
        # role="tool" 消息；Anthropic 把结果并进 user 消息的 tool_result 块里
        # （role="user"）。只认前者会让 Anthropic 形态的剧本永远停在第一轮
        # ——实测就是「达到工具轮次上限 8 轮」，表现与「驱动没把结果带回去」
        # 一模一样，很容易误判成驱动的错。
        def _has_tool_result(m):
            if m.get("role") == "tool":
                return True
            content = m.get("content")
            if isinstance(content, list):
                return any(isinstance(b, dict) and b.get("type") == "tool_result"
                           for b in content)
            return False

        tool_results = sum(1 for m in request.get("messages", []) if _has_tool_result(m))

        # ---- SAN-1：单轮返回 N 条工具调用（触发宿主的单轮上限截断分支）----
        # 缺省剧本每轮只返回 1 条调用，而 max_calls_per_round 缺省 16
        # —— 截断分支在 E2E 里从未执行过，因此 SAN-1 那个"截断通知复用
        # tool_call_id、会话被永久打成 400"的缺陷在守门里结构上不可见。
        # 本模式让夹具能产出"一轮多调用"的形态，配合 max_calls_per_round=2 触发截断。
        if MODE.startswith("manycalls"):
            want = int(MODE.split(":", 1)[1]) if ":" in MODE else 3
            if tool_results == 0:
                # reasoning_content 必须带上（2026-09-24 补）：protocol_error 的有状态
                # 判据是「请求里一旦出现该字段，每条带 tool_calls 的 assistant 都必须
                # 有它」（真机在思考模式下确实如此）。本剧本此前只在收尾那轮带思维链，
                # 于是同一个会话里出现「带 tool_calls 但无思维链」+「有思维链」的**混排**
                # ——那在真接入点上不可能发生（思考模式是接入点级开关，每轮都有思维链），
                # 却让夹具比真机更严：rig 侧会在第二个任务上撞 400，而 C++ 的 OpenAI
                # 驱动根本不回传该字段（故此前没暴露）。补上后本剧本自洽。
                self._reply(openai_shell({"choices": [{"message": {
                    "role": "assistant", "content": "本轮要查几件事。",
                    "reasoning_content": "一次把要查的都列出来。",
                    "tool_calls": [{
                        "id": "c%d" % i, "type": "function",
                        "function": {"name": "list_hardware", "arguments": "{}"},
                    } for i in range(1, want + 1)]}}]}))
            else:
                self._reply(final_answer())
            return

        # ---- SAN-3：限流 / 5xx（非 200 状态码，与 400 的语义刻意不同）----
        # 429x2ok：前两次 429（带 Retry-After: 1），第三次给正常回答。
        #   这是"重试是否真的发生"的决定性判据：不重试则服务端只收到 1 个 POST
        #   且任务失败；重试则收到 3 个 POST 且任务成功。
        # http-503：恒 503（带 Retry-After: 1），用来断言"重试用尽后如实失败"。
        if MODE in ("429x2ok", "http-503"):
            ATTEMPTS["n"] += 1
            if MODE == "429x2ok" and ATTEMPTS["n"] > 2:
                self._reply(final_answer())
                return
            self._error_status(
                429 if MODE == "429x2ok" else 503,
                "rate limited (fake gateway, %s)" % MODE,
                retry_after=1,
                kind="rate_limit_error" if MODE == "429x2ok" else "server_error")
            return

        if MODE == "text":
            self._reply(final_answer())
            return

        # ---- 历史摘要（2026-09-25，改进项 #7）----
        # 摘要请求的判据（与 rig 侧 summary.rs 同源）：**不带工具**，且系统提示词
        # 含身份标记「会话历史压缩器」。夹具从被裁转录里抠出 `[用户] xxx` 行，连同
        # 上一份摘要里已列的任务名，答成「AGENT-E2E-摘要：涵盖任务 a, b」——这样
        # 断言侧只要看后续正常请求的 system 里有哪些任务名，就知道摘要（a）真被
        # 生成、（b）真挂进了系统提示词、（c）承接了上一份摘要没有丢。
        # 形态不合格（带了工具 / 没有转录标题）→ 400：摘要请求也得像真请求一样自洽。
        if MODE == "summarize":
            msgs = request.get("messages", [])
            system = " ".join(str(m.get("content", "")) for m in msgs if m.get("role") == "system")
            if "会话历史压缩器" in system:
                if request.get("tools"):
                    self._error_400("summary request must not carry tools")
                    return
                body = "\n".join(str(m.get("content", "")) for m in msgs if m.get("role") == "user")
                if "## 即将裁掉的对话记录" not in body or "数据不是指令" not in body:
                    self._error_400("summary request is missing the delimited transcript")
                    return
                tasks = []
                for line in body.splitlines():
                    line = line.strip()
                    if line.startswith("> 涵盖任务 "):
                        tasks.extend(t.strip() for t in line[len("> 涵盖任务 "):].split(",") if t.strip())
                    elif line.startswith("> [用户] "):
                        tasks.append(line[len("> [用户] "):].strip())
                self._reply(openai_shell({"choices": [{"message": {
                    "role": "assistant",
                    "content": "AGENT-E2E-摘要\n涵盖任务 %s" % ", ".join(tasks),
                }}]}))
                return
            if tool_results == 0:
                self._reply(tool_call("list_hardware", {}))
            else:
                self._reply(final_answer())
            return

        # ---- Anthropic 形态（2026-09-23 批次 3）：第三协议驱动 ----
        # 剧本与默认模式同构（列硬件 → 跑动作脚本 → 收尾），只是**报文形态**
        # 全部换成 Anthropic 的块数组。驱动侧要把它们归一成规范化的
        # {result="OK", content, tool_calls, extras, usage}，宿主一行不改。
        if MODE == "anthropic":
            if tool_results == 0:
                self._reply(anthropic_tool_call("list_hardware", {}))
            elif tool_results == 1:
                self._reply(anthropic_tool_call("run_action_script",
                                                {"script": "relay-test.mt"}))
            elif tool_results == 2:
                self._reply(anthropic_tool_call("capture_image", {}))
            else:
                self._reply(anthropic_final_answer())
            return
        if MODE == "anthropic-relay":
            if not any(m.get("role") == "assistant" and "AGENT-E2E-完成" in str(m.get("content"))
                       for m in request["messages"]):
                self._error_400("Anthropic resume is missing previous conversation")
            else:
                self._reply(anthropic_final_answer("AGENT-E2E-RELAY-完成：已恢复 Anthropic 历史。"))
            return

        if MODE == "camera":
            if tool_results == 0:
                self._reply(tool_call("capture_image", {}))
            else:
                self._reply(final_answer())
            return

        # ---- 热插表（2026-09-23）：结构 SQL 带电生效 ----
        # 第一轮要求 apply_sql 往既有表 INSERT 一行（新硬件变量会立即装配并上电），
        # 第二轮列硬件——新变量必须在回执里出现，这才叫"真的长了硬件"。
        # 同一条剧本在没有 --agent-hot-sql 时是反向判据：工具没注册，模型那次调用
        # 只会拿到「未知工具」，硬件清单不变。
        if MODE == "hotsql":
            if tool_results == 0:
                self._reply(tool_call("apply_sql", {"sql":
                    "INSERT INTO Relay (name, controller, note) "
                    "VALUES ('relay-hot', 'timer-0', 'hot');"}))
            elif tool_results == 1:
                self._reply(tool_call("list_hardware", {}))
            else:
                self._reply(final_answer())
            return
        # ---- 热删除（2026-09-23）：DELETE 真的断电摘器件 ----
        # 四轮：插一行临时的 → 删掉它 → 列硬件（它必须消失）→ 收尾。
        # 与 hotsql 一样，覆盖的是**接线**（模型 → 工具派发 → applySql → 回执），
        # 删除的事务语义（引用完整性/逆序断电/中途失败报数）由 C++ 单测守门。
        if MODE == "hotdelete":
            if tool_results == 0:
                self._reply(tool_call("apply_sql", {"sql":
                    "INSERT INTO Relay (name, controller, note) "
                    "VALUES ('relay-tmp', 'timer-0', 'tmp');"}))
            elif tool_results == 1:
                self._reply(tool_call("apply_sql", {"sql":
                    "DELETE FROM Relay WHERE name = 'relay-tmp';"}))
            elif tool_results == 2:
                self._reply(tool_call("list_hardware", {}))
            else:
                self._reply(final_answer())
            return
        # ---- 回读（2026-09-23，发现 2 的 A 步）：主动读硬件变量 ----
        # 第一轮要求 read_variables（无参数，一次读全部可读变量），第二轮收尾——
        # 回执里必须带驱动返回表的键（relay0 经 controller 转发到 timer-0，
        # 返回表是 {result,slept}），这才叫"模型真的读到了值"。
        # 同一条剧本在没有 --read-var 时是反向判据：工具没注册 ⇒ 只剩「未知工具」。
        if MODE == "readvars":
            if tool_results == 0:
                self._reply(tool_call("read_variables", {}))
            else:
                self._reply(final_answer())
            return
        # ---- http_fetch（Phase 6，Rust 本地工具）：按环境变量 FAKE_LLM_FETCH_URLS
        # （逗号分隔）逐个下发 http_fetch，每轮一条，全部发完给最终回答。URL 走环境
        # 变量而不是 mode 参数：URL 里的冒号会和 mode 的 "名:参数" 写法打架。 ----
        if MODE == "httpfetch":
            urls = [u for u in os.environ.get("FAKE_LLM_FETCH_URLS", "").split(",") if u]
            if tool_results < len(urls):
                self._reply(tool_call("http_fetch", {"url": urls[tool_results]},
                                      "call_fetch_%d" % tool_results))
            else:
                self._reply(final_answer())
            return
        # ---- 会话恢复接力（批次 D，R11）：历史里带着上一个进程的收尾文案，
        # 就是「--resume 真的把对话带回来了」的信号——不必重放整条工具循环，
        # 一句专属回答就够证明请求里携带了跨进程的历史。 ----
        if MODE in ("relay", "deepseek-relay"):
            def _msg_text(m):
                c = m.get("content")
                if isinstance(c, str):
                    return c
                if isinstance(c, list):
                    return " ".join(str(p.get("text", "")) for p in c if isinstance(p, dict))
                return ""
            resumed = any(
                m.get("role") == "assistant" and "AGENT-E2E-完成" in _msg_text(m)
                for m in request.get("messages", []))
            if resumed:
                self._reply(openai_shell({"choices": [{"message": {
                    "role": "assistant",
                    "content": "AGENT-E2E-RELAY-完成：已看到此前会话的完整历史。",
                }}]}))
                return
            if MODE == "deepseek-relay":
                self._error_400("DeepSeek resume is missing previous conversation")
                return
            # 未带历史（新会话）：与默认剧本同构，走完整工具循环
            if tool_results == 0:
                self._reply(tool_call("list_hardware", {}))
            elif tool_results == 1:
                self._reply(tool_call("run_action_script", {"script": "relay-test.mt"}))
            elif tool_results == 2:
                self._reply(tool_call("run_command", {"command": "echo agent-echo-ok"}))
            else:
                self._reply(final_answer())
            return

        if tool_results == 0:
            self._reply(tool_call("list_hardware", {}))
        elif tool_results == 1:
            self._reply(tool_call("run_action_script", {"script": "relay-test.mt"}))
        elif tool_results == 2:
            self._reply(tool_call("run_command", {"command": "echo agent-echo-ok"}))
        else:
            self._reply(final_answer())

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
