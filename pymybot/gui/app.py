"""Tkinter front end: an agent-centric window over ``pymybot serve``.

The window owns no robot logic. It starts one long-lived ``python -m pymybot
serve`` child, turns its JSON-RPC notifications into chat lines and asks the
operator to approve each tool call the agent requests. Hardware access and
automatic action approval are GUI toggles that must be confirmed every launch;
they are never persisted.
"""
from __future__ import annotations

import json
import os
import queue
import sys
import threading
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, font as tkfont, messagebox, ttk
from tkinter.scrolledtext import ScrolledText

from .config import GuiConfig, config_home, default_workspace, merge_args
from .protocol import CANCELLED, CliCall, RpcError, ServeClient, cli_args, resolve_python

TITLE = "mybot · 智能体"
MAX_DIALOG_ARGS = 4000

PALETTE = {
    "bg": "#f5f6f8",
    "panel": "#ffffff",
    "ink": "#1f2328",
    "muted": "#6b7280",
    "accent": "#2563eb",
    "user": "#1d4ed8",
    "assistant": "#111827",
    "tool": "#6b7280",
    "toolerr": "#b91c1c",
    "error": "#b91c1c",
    "system": "#6b7280",
}


class GuiUnavailable(RuntimeError):
    """Raised when no Tk display is available."""


def _pick_font(root, candidates, size, fallback):
    available = set(tkfont.families(root))
    for name in candidates:
        if name in available:
            return (name, size)
    return (fallback, size)


def _brief(value, limit=160):
    if value is None:
        return ""
    try:
        text = json.dumps(value, ensure_ascii=False, sort_keys=False)
    except (TypeError, ValueError):
        text = str(value)
    text = " ".join(text.split())
    return text if len(text) <= limit else text[: limit - 1] + "…"


def _absolute(path, root):
    """GUI paths may be workspace-relative; the agent needs absolute ones."""
    text = str(path or "").strip()
    if not text:
        return ""
    candidate = Path(text)
    return str(candidate if candidate.is_absolute() else Path(root or ".") / candidate)


class App:
    def __init__(self, root, config: GuiConfig, config_path: Path):
        self.root = root
        self.cfg = config
        self.config_path = config_path
        self.queue: "queue.Queue" = queue.Queue()
        self.serve: ServeClient | None = None
        self.starting = False
        self.generation = 0
        self.greeted = False
        self.serve_state = "未启动"
        self.agent_available = False
        self.busy = False
        self.turn_id = None
        self.turn_text = 0
        self.at_line_start = True
        self.pending_task = ""
        self.hardware_job = None
        self._notice_job = None
        self._stopping = False

        self.font_ui = _pick_font(root, ("Microsoft YaHei UI", "Segoe UI", "Noto Sans CJK SC", "DejaVu Sans"), 10, "TkDefaultFont")
        self.font_mono = _pick_font(root, ("Cascadia Mono", "Consolas", "DejaVu Sans Mono", "Courier New"), 9, "TkFixedFont")

        self._style()
        self._build()
        self._load_robot_list()
        self._refresh_hardware()
        root.after(60, self._pump)
        root.protocol("WM_DELETE_WINDOW", self.on_close)
        root.after(120, self._start_server)
        if self.cfg.task.strip():
            self.task_box.insert("1.0", self.cfg.task.strip())
            self.task_box.focus_set()
        self._refresh_status()

    # -- construction ------------------------------------------------------
    def _style(self):
        style = ttk.Style(self.root)
        for name in ("vista", "winnative", "clam", "default"):
            if name in style.theme_names():
                style.theme_use(name)
                break
        style.configure("Toolbar.TFrame", background=PALETTE["bg"])
        style.configure("Side.TFrame", background=PALETTE["bg"])
        style.configure("TLabel", font=self.font_ui)
        style.configure("Muted.TLabel", foreground=PALETTE["muted"], font=self.font_ui)
        style.configure("Head.TLabel", font=(self.font_ui[0], 10, "bold"))
        style.configure("TButton", font=self.font_ui)
        style.configure("Send.TButton", font=(self.font_ui[0], 10, "bold"))
        style.configure("TLabelframe.Label", font=(self.font_ui[0], 9, "bold"))
        self.root.configure(background=PALETTE["bg"])

    def _build(self):
        self.root.title(TITLE)
        self.root.geometry("1180x780")
        self.root.minsize(940, 620)

        toolbar = ttk.Frame(self.root, style="Toolbar.TFrame", padding=(10, 8))
        toolbar.pack(side="top", fill="x")
        ttk.Button(toolbar, text="打开工作区", command=self.pick_workspace).pack(side="left")
        self.workspace_label = ttk.Label(toolbar, text="", style="Muted.TLabel")
        self.workspace_label.pack(side="left", padx=(8, 16))
        ttk.Label(toolbar, text="结构").pack(side="left")
        self.robot_box = ttk.Combobox(toolbar, width=34, state="readonly", values=[])
        self.robot_box.pack(side="left", padx=(6, 4))
        self.robot_box.bind("<<ComboboxSelected>>", lambda _event: self.on_robot_changed())
        ttk.Button(toolbar, text="⟳", width=3, command=self.refresh_context).pack(side="left")
        ttk.Separator(toolbar, orient="vertical").pack(side="left", fill="y", padx=12)
        self.new_button = ttk.Button(toolbar, text="新对话", command=self.new_conversation)
        self.new_button.pack(side="left")
        self.stop_button = ttk.Button(toolbar, text="■ 停止", command=self.stop_turn)
        self.stop_button.pack(side="left", padx=6)
        ttk.Button(toolbar, text="设置", command=self.open_settings).pack(side="right")

        # Reserve the status bar before the body: a tall side panel must never
        # push it out of the window.
        status = ttk.Frame(self.root, padding=(10, 4))
        status.pack(side="bottom", fill="x")
        self.status_state = ttk.Label(status, text="", style="Muted.TLabel")
        self.status_state.pack(side="left")
        self.status_agent = ttk.Label(status, text="", style="Muted.TLabel")
        self.status_agent.pack(side="left", padx=(14, 0))
        self.status_busy = ttk.Label(status, text="", style="Muted.TLabel")
        self.status_busy.pack(side="left", padx=(14, 0))
        self.status_notice = ttk.Label(status, text="", style="Muted.TLabel")
        self.status_notice.pack(side="left", padx=(14, 0))

        body = ttk.PanedWindow(self.root, orient="horizontal")
        body.pack(side="top", fill="both", expand=True, padx=10, pady=(0, 6))

        side = ttk.Frame(body, style="Side.TFrame", width=330)
        body.add(side, weight=0)
        self._build_side(side)

        right = ttk.Frame(body)
        body.add(right, weight=1)
        self._build_chat(right)

    def _build_side(self, host):
        # The context pane scrolls, so a long hardware list can never squeeze the
        # chat or push the window past the screen.
        canvas = tk.Canvas(host, highlightthickness=0, borderwidth=0,
                           background=PALETTE["bg"], width=318)
        scroll = ttk.Scrollbar(host, orient="vertical", command=canvas.yview)
        canvas.configure(yscrollcommand=scroll.set)
        canvas.pack(side="left", fill="both", expand=True)
        scroll.pack(side="right", fill="y")
        side = ttk.Frame(canvas, style="Side.TFrame")
        window = canvas.create_window((0, 0), window=side, anchor="nw")

        def resize(_event=None):
            canvas.configure(scrollregion=canvas.bbox("all"))

        def fit(event):
            canvas.itemconfigure(window, width=event.width)

        side.bind("<Configure>", resize)
        canvas.bind("<Configure>", fit)

        def wheel(event):
            canvas.yview_scroll(-1 if event.delta > 0 else 1, "units")

        canvas.bind("<Enter>", lambda _event: canvas.bind_all("<MouseWheel>", wheel))
        canvas.bind("<Leave>", lambda _event: canvas.unbind_all("<MouseWheel>"))

        robot = ttk.Labelframe(side, text="机器人上下文", padding=8)
        robot.pack(fill="x", padx=6, pady=(6, 6))
        self._side_entry(robot, "脚本根目录", self.cfg.scripts_dir, self._set_scripts_dir, row=0, browse=True)
        self._side_entry(robot, "技能目录", self.cfg.skills_dir, self._set_skills_dir, row=1, browse=True)
        self._side_entry(robot, "模块路径", self.cfg.module_paths[0] if self.cfg.module_paths else "", self._set_module_path, row=2)
        self._side_entry(robot, "图片源目录", self.cfg.camera_src_dir, self._set_camera_dir, row=3, browse=True)

        hardware = ttk.Labelframe(side, text="硬件", padding=8)
        hardware.pack(fill="x", padx=6, pady=(0, 6))
        self.hardware_tree = ttk.Treeview(hardware, columns=("type", "meta"), show="tree headings", height=6)
        self.hardware_tree.heading("#0", text="变量")
        self.hardware_tree.heading("type", text="驱动")
        self.hardware_tree.heading("meta", text="配置")
        self.hardware_tree.column("#0", width=110, stretch=False)
        self.hardware_tree.column("type", width=80, stretch=False)
        self.hardware_tree.column("meta", width=140)
        self.hardware_tree.pack(side="top", fill="both", expand=True)
        self.hardware_note = ttk.Label(hardware, text="选择结构后自动读取", style="Muted.TLabel")
        self.hardware_note.pack(side="top", anchor="w", pady=(4, 0))

        guard = ttk.Labelframe(side, text="权限与预算（每次启动重新确认）", padding=8)
        guard.pack(fill="x", padx=6, pady=(0, 6))
        self.hardware_var = tk.BooleanVar(value=bool(self.cfg.allow_hardware))
        self.actions_var = tk.BooleanVar(value=bool(self.cfg.allow_actions))
        ttk.Checkbutton(guard, text="允许硬件（--allow-hardware）", variable=self.hardware_var,
                        command=self.on_permission_toggle).grid(row=0, column=0, columnspan=2, sticky="w")
        ttk.Checkbutton(guard, text="自动批准动作（不再逐次确认）", variable=self.actions_var,
                        command=self.on_permission_toggle).grid(row=1, column=0, columnspan=2, sticky="w")
        ttk.Label(guard, text="读取变量").grid(row=2, column=0, sticky="w", pady=(6, 0))
        self.read_vars_entry = ttk.Entry(guard, width=18)
        self.read_vars_entry.insert(0, ",".join(self.cfg.read_vars))
        self.read_vars_entry.grid(row=2, column=1, sticky="ew", pady=(6, 0))
        ttk.Label(guard, text="相机变量").grid(row=3, column=0, sticky="w")
        self.camera_vars_entry = ttk.Entry(guard, width=18)
        self.camera_vars_entry.insert(0, ",".join(self.cfg.camera_vars))
        self.camera_vars_entry.grid(row=3, column=1, sticky="ew")
        ttk.Label(guard, text="超时 / 请求 / 工具").grid(row=4, column=0, sticky="w", pady=(6, 0))
        budgets = ttk.Frame(guard)
        budgets.grid(row=4, column=1, sticky="ew", pady=(6, 0))
        self.timeout_box = ttk.Spinbox(budgets, from_=1, to=3600, width=5)
        self.timeout_box.set(int(self.cfg.timeout))
        self.timeout_box.pack(side="left")
        self.requests_box = ttk.Spinbox(budgets, from_=1, to=100, width=4)
        self.requests_box.set(self.cfg.max_requests)
        self.requests_box.pack(side="left", padx=(6, 0))
        self.tools_box = ttk.Spinbox(budgets, from_=1, to=1000, width=4)
        self.tools_box.set(self.cfg.max_tool_calls)
        self.tools_box.pack(side="left", padx=(6, 0))
        guard.columnconfigure(1, weight=1)

        model = ttk.Labelframe(side, text="模型（在设置中修改）", padding=8)
        model.pack(fill="x", padx=6, pady=(0, 8))
        self.model_label = ttk.Label(model, text="", style="Muted.TLabel", wraplength=270)
        self.model_label.pack(anchor="w")
        self._refresh_model_label()

    def _side_entry(self, parent, label, value, setter, row, browse=False):
        ttk.Label(parent, text=label).grid(row=row, column=0, sticky="w", pady=(0 if row == 0 else 4, 0))
        frame = ttk.Frame(parent)
        frame.grid(row=row, column=1, sticky="ew", pady=(0 if row == 0 else 4, 0), padx=(6, 0))
        entry = ttk.Entry(frame, width=20)
        entry.insert(0, value or "")
        entry.pack(side="left", fill="x", expand=True)
        entry.bind("<FocusOut>", lambda _event: setter(entry.get()))
        if browse:
            ttk.Button(frame, text="…", width=3, command=lambda: setter(self._browse_into(entry))).pack(side="left")
        parent.columnconfigure(1, weight=1)
        return entry

    def _build_chat(self, right):
        # The composer is reserved at the bottom before the transcript grows.
        composer = ttk.Frame(right, padding=(0, 6, 0, 0))
        composer.pack(side="bottom", fill="x")
        self.notebook = ttk.Notebook(right)
        self.notebook.pack(side="top", fill="both", expand=True)

        chat_frame = ttk.Frame(self.notebook)
        self.chat = ScrolledText(chat_frame, wrap="word", state="disabled", font=self.font_ui,
                                 background=PALETTE["panel"], foreground=PALETTE["ink"], relief="flat", padx=10, pady=8)
        self.chat.pack(side="top", fill="both", expand=True)
        self.chat.tag_configure("user", foreground=PALETTE["user"], font=(self.font_ui[0], 10, "bold"),
                                spacing1=6, spacing3=2)
        self.chat.tag_configure("assistant", foreground=PALETTE["assistant"], spacing3=2)
        self.chat.tag_configure("tool", foreground=PALETTE["tool"], font=self.font_mono, lmargin1=12, lmargin2=12)
        self.chat.tag_configure("toolerr", foreground=PALETTE["toolerr"], font=self.font_mono, lmargin1=12, lmargin2=12)
        self.chat.tag_configure("error", foreground=PALETTE["error"], spacing1=4)
        self.chat.tag_configure("system", foreground=PALETTE["system"], font=(self.font_ui[0], 9, "italic"), spacing1=4)
        self.notebook.add(chat_frame, text="对话")

        log_frame = ttk.Frame(self.notebook)
        self.log = ScrolledText(log_frame, wrap="none", state="disabled", font=self.font_mono,
                                background="#111827", foreground="#d1d5db", relief="flat", padx=8, pady=6)
        self.log.pack(side="top", fill="both", expand=True)
        self.notebook.add(log_frame, text="日志")

        self.task_box = tk.Text(composer, height=3, wrap="word", font=self.font_ui, relief="solid", borderwidth=1)
        self.task_box.pack(side="left", fill="both", expand=True)
        self.task_box.bind("<Control-Return>", self._send_shortcut)
        buttons = ttk.Frame(composer)
        buttons.pack(side="left", fill="y", padx=(6, 0))
        self.send_button = ttk.Button(buttons, text="发送", style="Send.TButton", command=self.send_task)
        self.send_button.pack(side="top", fill="x", ipady=6)
        ttk.Label(buttons, text="Ctrl+Enter", style="Muted.TLabel").pack(side="top", pady=(4, 0))

    # -- helpers -----------------------------------------------------------
    def post(self, callback):
        """Queue a callable for the Tk thread; safe to call from any thread."""
        self.queue.put(callback)

    def _pump(self):
        if self._stopping:
            return
        while True:
            try:
                callback = self.queue.get_nowait()
            except queue.Empty:
                break
            try:
                callback()
            except tk.TclError:
                return  # the window is going away
            except Exception as exc:  # a broken callback must not kill the pump
                print(f"pymybot gui: {type(exc).__name__}: {exc}", file=sys.stderr)
        self.root.after(60, self._pump)

    def _background(self, fn, done):
        def run():
            try:
                value = fn()
            except Exception as exc:
                error = exc  # `exc` is cleared when the except block ends
                self.post(lambda: done(None, error))
                return
            self.post(lambda: done(value, None))

        threading.Thread(target=run, daemon=True).start()

    def _notice(self, text, seconds=8):
        self.status_notice.configure(text=text)
        if self._notice_job is not None:
            self.root.after_cancel(self._notice_job)
        self._notice_job = self.root.after(seconds * 1000, lambda: self.status_notice.configure(text=""))

    def _log(self, chunk):
        if not chunk or self._stopping:
            return
        self.log.configure(state="normal")
        self.log.insert("end", chunk if chunk.endswith("\n") else chunk + "\n")
        self.log.see("end")
        self.log.configure(state="disabled")

    def _chat_line(self, text, tag=None):
        if self._stopping:
            return
        prefix = "" if self.at_line_start else "\n"
        self.chat.configure(state="normal")
        self.chat.insert("end", prefix + text + "\n", tag or ())
        self.chat.see("end")
        self.chat.configure(state="disabled")
        self.at_line_start = True

    def _chat_delta(self, text):
        if not text or self._stopping:
            return
        self.chat.configure(state="normal")
        self.chat.insert("end", text, "assistant")
        self.chat.see("end")
        self.chat.configure(state="disabled")
        self.at_line_start = False
        self.turn_text += len(text)

    # -- configuration -----------------------------------------------------
    def _browse_into(self, entry):
        chosen = filedialog.askdirectory(initialdir=self.cfg.workspace or default_workspace())
        if chosen:
            entry.delete(0, "end")
            entry.insert(0, chosen)
        return entry.get()

    def _set_scripts_dir(self, value):
        self.cfg.scripts_dir = value.strip()

    def _set_skills_dir(self, value):
        self.cfg.skills_dir = value.strip()

    def _set_module_path(self, value):
        self.cfg.module_paths = [item.strip() for item in value.split(os.pathsep) if item.strip()]

    def _set_camera_dir(self, value):
        self.cfg.camera_src_dir = value.strip()

    def _refresh_model_label(self):
        model = self.cfg.model or os.environ.get("MYBOT_MODEL", "")
        key_env = self.cfg.api_key_env or "厂商默认变量"
        endpoint = self.cfg.base_url or "厂商默认"
        self.model_label.configure(
            text=f"模型：{model or '未设置（需 MYBOT_MODEL）'}\n端点：{endpoint}\n密钥变量：{key_env}"
        )

    def pick_workspace(self):
        chosen = filedialog.askdirectory(initialdir=self.cfg.workspace or default_workspace())
        if not chosen:
            return
        self.cfg.workspace = chosen
        self.cfg.robot = ""
        self._load_robot_list()
        self._restart_server()

    def _load_robot_list(self):
        self.workspace_label.configure(text=self.cfg.workspace or default_workspace())
        root = Path(self.cfg.workspace or default_workspace())
        found = []
        for base in (root / "robots", root):
            if base.is_dir():
                found.extend(sorted(str(path) for path in base.glob("*.sql") if path.is_file()))
        unique = []
        for path in found:
            if path not in unique:
                unique.append(path)
        try:
            shown = [Path(os.path.relpath(path, root)).as_posix() for path in unique]
        except ValueError:
            shown = unique
        self.robot_box.configure(values=shown)
        current = self.cfg.robot
        if current:
            try:
                current = Path(os.path.relpath(current, root)).as_posix()
            except ValueError:
                pass
        if current in shown:
            self.robot_box.set(current)
        elif shown:
            self.robot_box.set(shown[0])
            self.cfg.robot = unique[0]
        else:
            self.robot_box.set("")
            self.cfg.robot = ""

    def on_robot_changed(self):
        shown = self.robot_box.get()
        if shown:
            root = self.cfg.workspace or default_workspace()
            self.cfg.robot = shown if os.path.isabs(shown) else os.path.join(root, shown)
        self.refresh_context()

    def _robot_path(self):
        return _absolute(self.cfg.robot, self.cfg.workspace or default_workspace())

    def _scripts_root(self):
        root = self.cfg.workspace or default_workspace()
        configured = _absolute(self.cfg.scripts_dir, root)
        if configured:
            return configured
        candidate = Path(root) / "scripts"
        return str(candidate if candidate.is_dir() else Path(root))

    def _module_paths(self):
        root = self.cfg.workspace or default_workspace()
        return [_absolute(item, root) for item in self.cfg.module_paths if str(item).strip()]

    # -- serve lifecycle ---------------------------------------------------
    def _start_server(self):
        if self.serve is not None or self.starting or self._stopping:
            return
        self.starting = True
        self.generation += 1
        generation = self.generation
        self.serve_state = "启动中…"
        self._refresh_status()
        workspace = self.cfg.workspace or default_workspace()
        python = resolve_python(workspace, self.cfg.python)

        def work():
            client = ServeClient(
                python,
                workspace,
                on_notify=lambda method, params: self.post(lambda: self._on_notify(generation, method, params)),
                on_request=lambda ident, method, params: self.post(
                    lambda: self._on_request(generation, ident, method, params)
                ),
                on_stderr=lambda chunk: self.post(lambda: self._log(chunk)),
                on_exit=lambda code: self.post(lambda: self._on_serve_exit(generation, code)),
            )
            try:
                info = client.request("initialize", timeout=90)
            except BaseException:
                client.stop(grace=2)
                raise
            return client, info

        self._background(work, lambda value, error: self._server_started(generation, value, error))

    def _server_started(self, generation, value, error):
        if generation != self.generation:
            return
        self.starting = False
        if error is not None:
            self.serve = None
            self.serve_state = f"启动失败：{error}"
            self._log(f"[gui] serve 启动失败：{error}\n")
            self._chat_line(f"✗ 无法启动 pymybot serve：{error}", "error")
            self._chat_line("检查 Python 解释器与 pymybot 安装；也可以在设置里指定解释器。", "system")
            self._refresh_status()
            return
        client, info = value
        self.serve = client
        self.agent_available = bool(info.get("agent"))
        self.serve_state = f"就绪（协议 {info.get('protocol')}）"
        self._log(f"[gui] serve 就绪：{json.dumps(info, ensure_ascii=False)}\n")
        if not self.agent_available:
            self._chat_line("智能体不可用：当前解释器缺少 PydanticAI 依赖。", "error")
            self._chat_line("安装 pymybot[agent] 后重启本窗口；或用 --no-gui 走命令行控制器。", "system")
        elif not self.greeted:
            self.greeted = True
            self._chat_line("与机器人对话即可：模型会先列出硬件，再按需运行动作脚本。", "system")
        self._refresh_status()
        if self.pending_task:
            task, self.pending_task = self.pending_task, ""
            self._send(task)

    def _restart_server(self):
        client, self.serve = self.serve, None
        self.agent_available = False
        self.generation += 1  # anything still arriving from the old child is stale
        self.serve_state = "重新启动…"
        if client is not None:
            threading.Thread(target=client.stop, daemon=True).start()
        self.root.after(150, self._start_server)
        self._refresh_status()

    def _on_serve_exit(self, generation, code):
        if generation != self.generation:
            return
        self.serve = None
        self.agent_available = False
        self.serve_state = f"已退出（{code}）"
        if self.busy:
            self.busy = False
            self.turn_id = None
            self._chat_line("✗ pymybot serve 已退出；本轮结果未知，检查机器人后再重试。", "error")
        self._set_busy(False)
        self._refresh_status()

    # -- notifications -----------------------------------------------------
    def _on_notify(self, generation, method, params):
        if generation != self.generation:
            return
        if method == "session":
            self.agent_available = bool(params.get("agent")) or self.agent_available
            self._refresh_status()
        elif method == "agent.event":
            self._on_agent_event(params)
        elif method == "sample":
            self._log(f"[sample] {_brief(params)}\n")

    def _on_request(self, generation, ident, method, params):
        if generation != self.generation:
            return
        if method != "confirm":
            self.serve_respond(ident, None)
            return
        approved = self._ask_tool(params)
        self.serve_respond(ident, {"approved": approved})

    def serve_respond(self, ident, result):
        if self.serve is None:
            return
        try:
            self.serve.respond(ident, result)
        except RpcError as exc:
            self._log(f"[gui] 回复失败：{exc}\n")

    def _on_agent_event(self, params):
        if params.get("id") != self.turn_id:
            return
        event = params.get("event") or {}
        kind = event.get("type")
        if kind == "text_delta":
            self._chat_delta(str(event.get("text") or ""))
        elif kind == "tool_call":
            self._chat_line(f"→ {event.get('tool')} {_brief(event.get('arguments'))}", "tool")
        elif kind == "tool_result":
            tool = event.get("tool")
            ok = event.get("ok")
            state = event.get("state")
            status = "" if ok is None else ("ok" if ok else "失败")
            if state:
                status = f"{status} / {state}" if status else str(state)
            self._chat_line(f"⇦ {tool} {status}".rstrip(), "tool" if ok is not False else "toolerr")

    # -- agent turn --------------------------------------------------------
    def _send_shortcut(self, _event=None):
        self.send_task()
        return "break"

    def send_task(self):
        task = self.task_box.get("1.0", "end").strip()
        if not task:
            return
        if self.busy:
            self._notice("上一轮还在执行，先点停止或等待完成")
            return
        if self.serve is None:
            self.pending_task = task
            self._notice("正在启动 pymybot serve…")
            self._start_server()
            return
        if not self.agent_available:
            self._notice("智能体不可用：缺少 PydanticAI 依赖")
            return
        robot = self._robot_path()
        if not robot or not Path(robot).is_file():
            messagebox.showwarning("需要结构文件", "先选择机器人结构（.sql）文件。", parent=self.root)
            return
        scripts = self._scripts_root()
        if not Path(scripts).is_dir():
            messagebox.showwarning("脚本目录不存在", f"脚本根目录不存在：\n{scripts}", parent=self.root)
            return
        self.task_box.delete("1.0", "end")
        self._send(task)

    def _send(self, task):
        if self.serve is None or not self.agent_available or self.busy:
            return
        if self.hardware_var.get() and not self._confirm_hardware():
            return
        params = {
            "task": task,
            "robot": self._robot_path(),
            "scriptsDir": self._scripts_root(),
            "cameraSrcDir": _absolute(self.cfg.camera_src_dir, self.cfg.workspace),
            "skillsDir": _absolute(self.cfg.skills_dir, self.cfg.workspace),
            "readVars": self._names(self.read_vars_entry.get()),
            "cameraVars": self._names(self.camera_vars_entry.get()),
            "allowActions": bool(self.actions_var.get()),
            "allowHardware": bool(self.hardware_var.get()),
            "timeout": self._number(self.timeout_box, 180),
            "maxRequests": int(self._number(self.requests_box, 8)),
            "maxToolCalls": int(self._number(self.tools_box, 16)),
        }
        params["modulePaths"] = self._module_paths()
        for key in ("model", "baseUrl", "apiKeyEnv"):
            value = getattr(self.cfg, {"model": "model", "baseUrl": "base_url", "apiKeyEnv": "api_key_env"}[key])
            if value:
                params[key] = value
        params = {key: value for key, value in params.items() if value not in ("", [], None)}
        try:
            ident, future = self.serve.start_request("agent.ask", params)
        except RpcError as exc:
            self._chat_line(f"✗ {exc}", "error")
            return

        self._chat_line(f"你：{task}", "user")
        self.turn_id = ident
        self.turn_text = 0
        self.at_line_start = True
        self.busy = True
        self._set_busy(True)
        self._background(lambda: future.result(), lambda value, error: self._turn_done(ident, value, error))

    def _turn_done(self, ident, result, error):
        if ident != self.turn_id:
            return
        self.busy = False
        self.turn_id = None
        self._set_busy(False)
        if error is not None:
            if isinstance(error, RpcError) and error.code == CANCELLED:
                self._chat_line("[已停止]", "system")
            else:
                self._chat_line(f"✗ {error}", "error")
                for event in getattr(error, "tool_events", []):
                    self._chat_line(f"  {_brief(event, 200)}", "system")
            self._refresh_status()
            return
        if self.turn_text == 0 and result.get("output"):
            self._chat_delta(str(result["output"]))
        usage = result.get("usage") or {}
        self._chat_line(
            "[完成 · 请求 {requests} · 工具 {tool_calls} · tokens {input_tokens}/{output_tokens}]".format(
                requests=usage.get("requests", "?"),
                tool_calls=usage.get("tool_calls", "?"),
                input_tokens=usage.get("input_tokens", "?"),
                output_tokens=usage.get("output_tokens", "?"),
            ),
            "system",
        )
        self._refresh_status()

    def stop_turn(self):
        if not self.busy or self.serve is None or self.turn_id is None:
            return
        self.serve.cancel(self.turn_id)
        self._notice("已请求停止…")

    def new_conversation(self):
        if self.busy:
            self._notice("先停止当前这一轮")
            return
        if self.serve is None:
            self._start_server()
            return
        ident, future = self.serve.start_request("agent.reset", {})
        self._background(lambda: future.result(), lambda _value, error: self._on_reset(error))

    def _on_reset(self, error):
        if error is not None:
            self._chat_line(f"✗ 重置失败：{error}", "error")
            return
        self._chat_line("[新对话，硬件已释放]", "system")

    # -- approvals ---------------------------------------------------------
    def on_permission_toggle(self):
        # The actual approval dialog is shown per turn, immediately before the
        # agent may touch hardware; the checkbox only reflects the intent.
        self._refresh_status()

    def _confirm_hardware(self):
        return messagebox.askokcancel(
            "确认硬件权限",
            "即将以 --allow-hardware 运行：会打开物理设备，激活本身就可能写硬件。\n\n"
            "只对已审阅的可信结构文件与驱动授权。",
            icon="warning",
            parent=self.root,
        )

    def _ask_tool(self, params):
        tool = str(params.get("tool") or "?")
        try:
            arguments = json.dumps(params.get("arguments"), indent=2, ensure_ascii=False, sort_keys=True)
        except (TypeError, ValueError):
            arguments = repr(params.get("arguments"))
        if len(arguments) > MAX_DIALOG_ARGS:
            messagebox.showwarning(
                "拒绝：参数过长",
                f"工具 {tool} 的参数超过 {MAX_DIALOG_ARGS} 字符，无法完整审阅，已拒绝。",
                parent=self.root,
            )
            self._chat_line(f"⊘ {tool} 已拒绝（参数过长）", "toolerr")
            return False
        dialog = ToolDialog(self.root, tool, arguments)
        self.root.wait_window(dialog.top)
        self._chat_line(f"{'✓' if dialog.approved else '⊘'} {tool} {'已批准' if dialog.approved else '已拒绝'}", "tool")
        return dialog.approved

    # -- context -----------------------------------------------------------
    def refresh_context(self):
        self._refresh_hardware()
        self._load_robot_list()

    def _refresh_hardware(self):
        robot = self._robot_path()
        for row in self.hardware_tree.get_children():
            self.hardware_tree.delete(row)
        self.hardware_note.configure(text="读取中…")
        if not robot or not Path(robot).is_file():
            self.hardware_note.configure(text="未选择结构文件")
            return
        workspace = self.cfg.workspace or default_workspace()
        python = resolve_python(workspace, self.cfg.python)
        try:
            args = cli_args(
                "hardware",
                robot=robot,
                module_paths=self._module_paths(),
                camera_src_dir=_absolute(self.cfg.camera_src_dir, workspace),
            )
        except ValueError as exc:
            self.hardware_note.configure(text=str(exc))
            return

        def work():
            return CliCall(python, args, workspace, on_stderr=lambda line: self.post(lambda: self._log(line))).wait()

        def done(result, error):
            if error is not None:
                self.hardware_note.configure(text=f"读取失败：{error}")
                return
            payload = result.json or {}
            if not payload.get("ok"):
                message = (payload.get("error") or {}).get("message") or result.stderr.strip() or "未知错误"
                self.hardware_note.configure(text=f"读取失败：{message}")
                return
            items = payload.get("hardware") or []
            for item in items:
                self.hardware_tree.insert("", "end", text=item.get("name", ""),
                                          values=(item.get("type", ""), _brief(item.get("metadata"), 80)))
            self.hardware_note.configure(text=f"{len(items)} 个变量（未激活）")

        self._background(work, done)

    def _names(self, text):
        names = []
        for item in str(text).replace("，", ",").split(","):
            name = item.strip()
            if name and name.isidentifier() and name not in names:
                names.append(name)
        return names

    @staticmethod
    def _number(box, default):
        try:
            return float(box.get())
        except (TypeError, ValueError):
            return float(default)

    # -- settings ----------------------------------------------------------
    def open_settings(self):
        dialog = SettingsDialog(self.root, self.cfg, self.cfg.workspace or default_workspace())
        self.root.wait_window(dialog.top)
        if not dialog.result:
            return
        before = (self.cfg.workspace, self.cfg.python)
        for name, value in dialog.result.items():
            setattr(self.cfg, name, value)
        self.cfg.task = ""
        self._save()
        self._refresh_model_label()
        self._load_robot_list()
        self._refresh_hardware()
        if before != (self.cfg.workspace, self.cfg.python):
            self._restart_server()
        self._notice("设置已保存")

    def _save(self):
        try:
            self.cfg.store(self.config_path)
        except OSError as exc:
            self._notice(f"设置保存失败：{exc}")

    # -- status ------------------------------------------------------------
    def _refresh_status(self):
        self.status_state.configure(text=f"服务：{self.serve_state}")
        self.status_agent.configure(text="智能体：可用" if self.agent_available else "智能体：不可用")
        flags = []
        if self.hardware_var.get():
            flags.append("允许硬件")
        if self.actions_var.get():
            flags.append("自动批准动作")
        busy = "执行中…" if self.busy else "空闲"
        self.status_busy.configure(text=busy + ("（" + "、".join(flags) + "）" if flags else ""))

    def _set_busy(self, busy):
        state = "disabled" if busy else "normal"
        self.send_button.configure(state=state)
        self.new_button.configure(state=state)
        self._refresh_status()

    # -- shutdown ----------------------------------------------------------
    def on_close(self):
        if self.busy and not messagebox.askokcancel("退出", "本轮仍在执行：退出会取消它，且已派发的动作不会回滚。继续？", parent=self.root):
            return
        self._stopping = True
        self._save()
        client = self.serve
        self.serve = None
        self.root.withdraw()

        def stop():
            if client is not None:
                try:
                    client.stop()
                except Exception:
                    pass
            self.post(self.root.destroy)

        threading.Thread(target=stop, daemon=True).start()
        # Hard stop if the child refuses to exit; destroy() is idempotent here.
        self.root.after(12000, self._force_destroy)

    def _force_destroy(self):
        try:
            self.root.destroy()
        except tk.TclError:
            pass


class ToolDialog:
    """Modal approval dialog; close means deny."""

    def __init__(self, parent, tool, arguments):
        self.approved = False
        top = self.top = tk.Toplevel(parent)
        top.title("智能体请求调用工具")
        top.transient(parent)
        top.resizable(True, True)
        top.minsize(520, 320)
        body = ttk.Frame(top, padding=12)
        body.pack(fill="both", expand=True)
        ttk.Label(body, text=f"工具：{tool}", style="Head.TLabel").pack(anchor="w")
        ttk.Label(body, text="下面是模型给出的完整参数；批准后本次调用立即执行。", style="Muted.TLabel").pack(anchor="w", pady=(4, 8))
        text = ScrolledText(body, wrap="none", font="TkFixedFont", height=12)
        text.insert("1.0", arguments)
        text.configure(state="disabled")
        text.pack(fill="both", expand=True)
        row = ttk.Frame(body)
        row.pack(fill="x", pady=(10, 0))
        ttk.Button(row, text="拒绝", command=self._deny).pack(side="right")
        approve = ttk.Button(row, text="批准并执行", style="Send.TButton", command=self._approve)
        approve.pack(side="right", padx=(0, 6))
        top.protocol("WM_DELETE_WINDOW", self._deny)
        top.bind("<Escape>", lambda _event: self._deny())
        approve.focus_set()
        top.wait_visibility()
        top.grab_set()

    def _approve(self):
        self.approved = True
        self.top.destroy()

    def _deny(self):
        self.approved = False
        self.top.destroy()


class SettingsDialog:
    """Small form for the persisted preferences; returns a partial GuiConfig."""

    FIELDS = (
        ("workspace", "工作区"),
        ("python", "Python 解释器"),
        ("model", "模型（provider:model）"),
        ("base_url", "端点 Base URL"),
        ("api_key_env", "API Key 环境变量名"),
        ("scripts_dir", "脚本根目录"),
        ("skills_dir", "技能目录"),
        ("camera_src_dir", "图片源目录"),
        ("module_paths", "模块路径（每行一个）"),
    )

    def __init__(self, parent, cfg: GuiConfig, workspace):
        self.result = None
        top = self.top = tk.Toplevel(parent)
        top.title("设置")
        top.transient(parent)
        body = ttk.Frame(top, padding=12)
        body.pack(fill="both", expand=True)
        body.columnconfigure(1, weight=1)
        self.entries = {}
        row = 0
        for name, label in self.FIELDS:
            ttk.Label(body, text=label).grid(row=row, column=0, sticky="nw", pady=3)
            if name == "module_paths":
                widget = tk.Text(body, height=3, width=46, font="TkFixedFont")
                widget.insert("1.0", "\n".join(getattr(cfg, name)))
            else:
                widget = ttk.Entry(body, width=50)
                widget.insert(0, str(getattr(cfg, name) or ""))
            widget.grid(row=row, column=1, sticky="ew", pady=3)
            if name in {"workspace", "scripts_dir", "skills_dir", "camera_src_dir"}:
                ttk.Button(body, text="…", width=3,
                           command=lambda w=widget: self._browse(w, workspace)).grid(row=row, column=2, sticky="w", padx=(4, 0))
            self.entries[name] = widget
            row += 1
        budgets = ttk.Frame(body)
        budgets.grid(row=row, column=1, sticky="w", pady=6)
        self.timeout = ttk.Spinbox(budgets, from_=1, to=3600, width=6)
        self.timeout.set(int(cfg.timeout))
        self.timeout.pack(side="left")
        ttk.Label(budgets, text="秒").pack(side="left", padx=(2, 10))
        self.requests = ttk.Spinbox(budgets, from_=1, to=100, width=4)
        self.requests.set(cfg.max_requests)
        self.requests.pack(side="left")
        ttk.Label(budgets, text="请求").pack(side="left", padx=(2, 10))
        self.tools = ttk.Spinbox(budgets, from_=1, to=1000, width=5)
        self.tools.set(cfg.max_tool_calls)
        self.tools.pack(side="left")
        ttk.Label(budgets, text="工具调用").pack(side="left", padx=(2, 0))
        ttk.Label(body, text="超时 / 预算", ).grid(row=row, column=0, sticky="w", pady=6)
        row += 1
        ttk.Label(body, text="密钥只读取环境变量，窗口不保存也不显示它。", style="Muted.TLabel").grid(
            row=row, column=0, columnspan=3, sticky="w", pady=(4, 0))
        row += 1
        buttons = ttk.Frame(body)
        buttons.grid(row=row, column=0, columnspan=3, sticky="e", pady=(10, 0))
        ttk.Button(buttons, text="取消", command=top.destroy).pack(side="right")
        ttk.Button(buttons, text="保存", style="Send.TButton", command=self._save).pack(side="right", padx=(0, 6))
        top.protocol("WM_DELETE_WINDOW", top.destroy)
        top.bind("<Escape>", lambda _event: top.destroy())
        top.wait_visibility()
        top.grab_set()

    def _browse(self, widget, workspace):
        chosen = filedialog.askdirectory(initialdir=workspace)
        if not chosen:
            return
        widget.delete("0", "end")
        widget.insert(0, chosen)

    def _save(self):
        values = {}
        for name, widget in self.entries.items():
            if name == "module_paths":
                values[name] = [line.strip() for line in widget.get("1.0", "end").splitlines() if line.strip()]
            else:
                values[name] = widget.get().strip()
        try:
            values["timeout"] = float(self.timeout.get())
            values["max_requests"] = int(self.requests.get())
            values["max_tool_calls"] = int(self.tools.get())
        except ValueError:
            messagebox.showwarning("设置无效", "超时与预算必须是数字。", parent=self.top)
            return
        self.result = values
        self.top.destroy()


def run_gui(args):
    """Entry point from ``pymybot gui`` / the default (no subcommand) route."""
    path = config_home() / "settings.json"
    config = merge_args(GuiConfig.load(path), args)
    config = config.sanitized()
    try:
        root = tk.Tk()
    except tk.TclError as exc:
        raise GuiUnavailable(str(exc)) from None
    app = App(root, config, path)
    try:
        root.mainloop()
    finally:
        if app.serve is not None:
            try:
                app.serve.stop(grace=3)
            except Exception:
                pass
    return {"closed": True}
