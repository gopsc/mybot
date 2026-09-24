# Web SSH 语义契约（wsproto / webterm / webshell）

> 本文是 #24「机器人工作台」Web SSH MVP（`feat/web-ssh`，PR #47）的**语义契约**
> 整理稿。定位：无论该功能继续以 C++ 单二进制演进、还是按维护者意见迁到
> Rust 重写，**行为不变式都以本文为准**——每一节给出「契约」与「对照实现时的
> 测试锚点」。权威实现是 `src/wsproto.{hpp,cpp}`、`src/webterm.{hpp,cpp}`、
> `src/webshell.{hpp,cpp}` 及 `test/cpp/test_wsproto.cpp`、`test_webterm.cpp`、
> `test_webshell.cpp`（667 基线全量含 233+86+247 条 Web SSH 用例，20 万轮
> Decoder 模糊测试零崩溃）。

## 拓扑总览

```
浏览器 (xterm.js) ──WebSocket──► webshell::run ──handleConnection──► webterm::Session ──forkpty──► shell
      ▲                                │                                    │
      └────────────── text 帧 ◄────────┘  pty 输出 → text 帧 ◄───────────────┘
```

- `GET /` → 单页前端（xterm.js CDN + WS 客户端，内嵌 HTML 字符串分发）
- `GET /ws/term?token=…` → HTTP 101 升级 → 文本帧双向桥接
- 每连接一个独立 `Session` 与 socket，无共享可变状态（线程隔离天然成立）

## 1. wsproto：RFC 6455 服务端最小协议层

自研理由：项目明示零第三方 C++ 依赖（同 jsonparse/sqlparse 取舍）；WebSocket
服务端只需「HTTP Upgrade 握手 + 帧编解码」，协议面小、可离线单测。

### 1.1 握手契约

- 只接受 `GET` + `Upgrade: websocket` + 合法 `Sec-WebSocket-Key`；其余回 400 文本
- 应答值：`Sec-WebSocket-Accept = Base64( SHA1( key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11" ) )`
- SHA1 按 RFC 3174 自实现；Base64 按 RFC 4648 §4 标准字母表含 padding
- 不校验 key 格式（16 字节 base64 由握手解析侧负责）

### 1.2 帧格式（§5.2）

```
byte0 = FIN(7) RSV1-3(6..4) opcode(3..0)
byte1 = MASK(7) len(6..0)   [len=126 → +2B 扩展；len=127 → +8B 扩展]
[mask key 4B]  payload（客户端帧逐字节异或 mask key）
opcode: 0=cont 1=text 2=binary 8=close 9=ping 10=pong
```

### 1.3 解码状态机（拒绝式，全部拒绝而非容错）

| 不变式 | 行为 |
| --- | --- |
| 客户端帧必须掩码（§5.1） | 未掩码 → 1002 关闭 |
| RSV 非零 | 1002 关闭 |
| 非法 opcode | 1002 关闭 |
| 控制帧（close/ping/pong）载荷 >125 | 1002 关闭 |
| 单条消息累积 > 64 KiB（`kMaxMessageBytes`） | 拒绝而非截断（同 jsonparse 字节上限取向） |
| 控制帧不可分片（FIN=0） | 1002 关闭 |
| 未在分片中的 continuation 帧 | 1002 关闭 |
| UTF-8 合法性 | MVP 透传字节（UTF-8 校验属应用层，由终端会话按需做） |

**Decoder 用法**：`feed()` 返回 `None`（有产出）或 `NeedMore`（等待输入）；
一次 feed 可产出 0..n 条消息（循环取 `messages()`）。**缓冲消费语义**：feed
返回前必须 erase 已消费字节——否则二次 feed 重复解析旧字节、分片状态机误报
`BadOpcode`（实测复现 Segfault，见 PR #47 修复记录）。

### 1.4 编码

- 服务端 → 客户端帧**不掩码**（§5.1 仅客户端须掩码）：`encodeFrame(opcode, payload, fin)`

### 测试锚点（test_wsproto.cpp，247 条）

- 握手：合法 key → 101 + Accept 值正确；缺头/错方法/错 Upgrade → 400
- 帧：未掩码、RSV、非法 opcode、控制帧 >125、分片控制、孤儿 continuation、超 64 KiB → 各错误码
- 20 万轮 Decoder 模糊测试零崩溃（任意字节序列喂入）

## 2. webterm：PTY 会话桥

职责：一条 WebSocket 连接 ↔ 一个伪终端上的交互 shell。

- WS 文本帧 → 写入 pty master；pty master 输出 → 封装成 text 帧返回
- `resize` 帧（应用层约定 `{ "op":"resize","rows":N,"cols":M }`）→ `TIOCSWINSZ`
- 实现：`forkpty(3)`（-lutil）——内核分配 pty 对，子进程在子会话中 exec 交互
  shell（`$SHELL` 或 `/bin/sh`）。纯 POSIX，无第三方依赖

### 生命周期契约

| 操作 | 契约 |
| --- | --- |
| 构造 | 即起会话（forkpty + exec shell） |
| `write(data)` | 写入 shell；返回实际写入字节数；-1 = 会话已死 |
| `drain(out, cap)` | 非阻塞排空 pty 输出（尽力而为，上限 cap）；返回是否仍有数据待读 |
| `resize(rows, cols)` | TIOCSWINSZ；返回成败 |
| `alive()` | `waitpid(WNOHANG)` 观察 + 内部收尸；shell 退出 → 会话结束，调用方应发 close 帧并关连接 |
| 析构 / `closeSession()` | 关 master + kill 子进程 + 收尸 |

**安全**：token 校验在握手层，**绝不进入本会话环境**；子进程不继承宿主敏感
环境变量之外的任何 Web SSH 专用状态。**exec 前关闭全部非 stdio fd**——子进程
继承 socket 会阻止对端 close 的 EOF 到达（实测复现连接泄漏）。

### 测试锚点（test_webterm.cpp，86 条）

- socketpair 直测泵：文本双向、resize 生效（TIOCSWINSZ）、alive 观察 shell 退出

## 3. webshell：服务主体

### 3.1 CLI 与互斥

- `--webshell-port` / `--webshell-host` / `--webshell-token`
- 与机器人模式互斥（启动校验）；token：**非回环监听强制非空**
- `run(host, portStr, token)` 为阻塞入口；`handleConnection(sock, token)` 独立可测

### 3.2 连接泵契约

- 握手失败 / token 校验失败 → 写 4xx 后关闭
- `readHeaders` 上限 16 KiB；`MSG_NOSIGNAL`（防 SIGPIPE 杀进程）
- poll 两路泵（socket → session；pty → socket），每连接一线程
- WS text 帧 → `session.write`（shell 输入）；`{"op":"resize",...}` → TIOCSWINSZ
- pty 输出 → text 帧回发；ping → pong；close 帧 / shell 退出 → 结束并关闭
- **协议错误一律以 close 1002 码收尾**

### 3.3 应用层消息

| 方向 | 消息 | 语义 |
| --- | --- | --- |
| 客户端 → 服务端 | 文本帧 | 原样写入 shell |
| 客户端 → 服务端 | `{"op":"resize","rows":N,"cols":M}` | 调整窗口 |
| 服务端 → 客户端 | 文本帧 | pty 原始输出（不做 UTF-8/终端转义，交由 xterm.js） |
| 双向 | ping / pong | 保活 |

### 测试锚点（test_webshell.cpp，233 条）

- socketpair 伪客户端完整走通：握手 + 双向泵 + resize + token 401 + 未掩码帧 1002

## 4. Rust 重写对照清单

迁 Rust 时逐条核对的**行为不变式**（每项都有 C++ 测试锚定，不应漂移）：

1. 握手只收 GET + Upgrade: websocket + 合法 key；Accept 值公式不变
2. 客户端帧必须掩码；RSV/非法 opcode/控制帧>125/分片控制/孤儿 cont/超 64 KiB 全拒绝
3. 单条消息上限 64 KiB：**拒绝**而非截断
4. Decoder.feed 缓冲消费语义：返回前 erase 已消费字节（防二次解析）
5. 服务端编码不掩码；close 错误码用 1002
6. forkpty + 子会话 exec $SHELL；exec 前关全部非 stdio fd（防 EOF 不达）
7. alive = waitpid(WNOHANG) 收尸；shell 退出即发 close 收尾
8. resize 应用层 JSON 字段 `{"op":"resize","rows","cols"}` → TIOCSWINSZ
9. readHeaders 16 KiB 上限；MSG_NOSIGNAL；每连接一线程/独立 session，无共享可变状态
10. token 非回环强制非空；握手层校验，不进入会话环境
11. 机器人模式与 Web SSH 模式互斥（CLI 校验）
12. 输出原样字节流（不做终端转义），前端 xterm.js 负责渲染

C++ 侧现有 566 条 Web SSH 用例 + 20 万轮模糊测试就是 Rust 侧的回归基线。
