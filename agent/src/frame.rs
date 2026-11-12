//! frame.rs —— mybot 后端的帧客户端（M1 `src/mcpbackend.cpp` 的镜像）
//!
//! 线格式与 pymsg/gomsg/libmsg 字节兼容：`[4 字节 big-endian uint32 载荷长][UTF-8 JSON]`。
//! 上限收紧到 **8 MiB**（对齐后端与 bot4cj JSON 解析器），在**分配载荷缓冲之前**
//! 检查长度（评估 §7.1）。单连接、lock-step、单一在途调用——故 `call` 取 `&mut self`，
//! 上层用 `Mutex` 串行化即可（正是物理安全要的语义）。
//!
//! 只做「一发一收」：不实现 libmsg 那些用不上的机制（线程池、broadcast、
//! retry_on_refused 的 1s 轮询、AsyncQueue），但**照抄它的加固清单**：分配前查上限、
//! 接收侧校验 UTF-8、超限即断。

use std::time::Duration;

use crate::out::errln;
use crate::protocol::{ERROR_FIELD, ROUTE_AUTH, ROUTE_FIELD, SUCCESS_FIELD, TOKEN_FIELD};
use anyhow::{anyhow, bail, Context, Result};
use serde_json::Value;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;
use tokio::time::{sleep, Instant};

/// 帧头长度：4 字节 big-endian uint32。
pub const HEADER_LEN: usize = 4;

/// 帧载荷上限：8 MiB——与后端 `src/mcpbackend.hpp` 的 `kMcpMaxFrameBytes` 是同一
/// 契约的两份常量（对齐 jsonparse 的 kJsonMaxBytes），改动必须双侧同步。
/// 跨语言一致由 C++ 侧 test_mcpbackend 的 mcpbackend_frame_limit_matches_rust_twin
/// 读本文件比对钉住（改本常量会红那条用例）。
pub const MAX_FRAME_BYTES: u32 = 8 * 1024 * 1024;

/// 读侧的**兜底** deadline（2026-09-30 审计 P1）。后端工具执行的最长合法等待 =
/// `--script-timeout` / `action_script_timeout_sec`（上限 3600s，见
/// src/agenttools.cpp 与 docs/agent.md 字段表）+ 组帧/认证余量。缺省用本值；
/// `--llm-task-timeout`（max_task_seconds）非零时 main.rs 会把读超时设成它——
/// 一轮任务的墙钟预算由此贯穿到工具调用**内部**（此前预算只判模型调用边界，
/// 后端进程活着但永不回帧时这条 await 无限挂起，模型侧超时与 Ctrl-C 都够
/// 不到它）。「不限」（max_task_seconds=0）也用本兜底：不限的是任务时长，
/// 不是「后端死了也要陪它挂到永远」。
pub const HARD_READ_CEILING: Duration = Duration::from_secs(3700);

/// 把载荷封成一帧：4 字节 BE 长度前缀 + 载荷。纯函数，便于单测。
pub fn encode_frame(payload: &[u8]) -> Result<Vec<u8>> {
    let len = payload.len();
    if len > MAX_FRAME_BYTES as usize {
        bail!("帧载荷 {len} 字节超过上限 {MAX_FRAME_BYTES}");
    }
    let mut frame = Vec::with_capacity(HEADER_LEN + len);
    frame.extend_from_slice(&(len as u32).to_be_bytes());
    frame.extend_from_slice(payload);
    Ok(frame)
}

/// 解析 4 字节帧头为载荷长度（big-endian）。纯函数，便于单测。
pub fn decode_len(hdr: &[u8; HEADER_LEN]) -> u32 {
    u32::from_be_bytes(*hdr)
}

/// 到 mybot 后端的单连接客户端。
pub struct BackendClient {
    stream: UnixStream,
    /// 单次调用 deadline：读侧 [`HARD_READ_CEILING`] 语义来源见其文档；写侧与
    /// 读侧共用（语义见 [`BackendClient::call`] 的写侧注释）。超时与 I/O 错误
    /// 同级：连接判死——lock-step 语义下超时后对端可能补收/补发，不可恢复。
    read_timeout: Duration,
}

impl BackendClient {
    /// 连接后端 AF_UNIX socket。后端可能晚起（上电、装结构脚本），故对连接失败
    /// 退避重试直到 `timeout`；超时则报错（不静默、不永久挂起）。
    pub async fn connect_timeout(path: &str, timeout: Duration) -> Result<Self> {
        let deadline = Instant::now() + timeout;
        let mut delay = Duration::from_millis(250);
        loop {
            match UnixStream::connect(path).await {
                Ok(stream) => {
                    return Ok(Self {
                        stream,
                        read_timeout: HARD_READ_CEILING,
                    })
                }
                Err(e) => {
                    if Instant::now() >= deadline {
                        return Err(anyhow!(
                            "连接后端超时（{}s），最后错误: {e}；路径 {path}",
                            timeout.as_secs()
                        ));
                    }
                    errln!(
                        "[mybot-agent] 后端未就绪（{e}），{}ms 后重试: {path}",
                        delay.as_millis()
                    );
                    sleep(delay).await;
                    if delay < Duration::from_secs(4) {
                        delay *= 2;
                    }
                }
            }
        }
    }

    /// 设置读侧 deadline（main.rs 按 `--llm-task-timeout` 装配；0/不限时保留
    /// [`HARD_READ_CEILING`] 兜底）。锁零散值不合法，≤0 一律回落兜底。
    pub fn set_read_timeout(&mut self, d: Duration) {
        self.read_timeout = d;
        if self.read_timeout.is_zero() {
            self.read_timeout = HARD_READ_CEILING;
        }
    }

    /// 从已建立的流构造（**测试缝**：单测用 `UnixStream::pair()` 注入假后端）。
    #[cfg(test)]
    pub fn from_stream(stream: UnixStream) -> Self {
        Self {
            stream,
            read_timeout: HARD_READ_CEILING,
        }
    }

    /// 发一个请求帧、收一个响应帧（lock-step）。任何协议违规（超限、非法 UTF-8、
    /// I/O 错误、读/写超时）都返回 Err——上层据此把连接判死，**下一次调用前**重连
    /// （见 bridge.rs 的 Conn::ensure）。在途调用本身不重试：回执丢失的
    /// `tool.call` 可能已在后端执行，重发即重复物理动作。
    pub async fn call(&mut self, req: &Value) -> Result<Value> {
        let payload = serde_json::to_vec(req).context("序列化请求")?;
        let frame = encode_frame(&payload)?;
        // 写侧 deadline（2026-10-01 审计 P2）：读侧修了（2026-09-30 P1）、写侧
        // 漏了——后端活着但不读 socket 时，超过内核 socket 缓冲（~200 KiB）的
        // write_all 会无限挂起，帧上限 8 MiB 下模型可控的大参数（长 SQL 等）可
        // 必现；--llm-task-timeout / HARD_READ_CEILING / Ctrl-C 轮询全都够不到
        // 这段 await。与读侧共用同一预算：单次调用的墙钟预算应覆盖整个一发一收。
        write_with_deadline(&mut self.stream, &frame, self.read_timeout, "写请求帧").await?;

        let mut hdr = [0u8; HEADER_LEN];
        read_exact_with_deadline(&mut self.stream, &mut hdr, self.read_timeout, "读响应帧头")
            .await?;
        let rlen = decode_len(&hdr);
        // 上限在**分配之前**检查（评估 §7.1）：u32 直接比较，无溢出暴露面。
        if rlen > MAX_FRAME_BYTES {
            bail!("响应帧 {rlen} 字节超过上限 {MAX_FRAME_BYTES}");
        }
        let mut buf = vec![0u8; rlen as usize];
        read_exact_with_deadline(&mut self.stream, &mut buf, self.read_timeout, "读响应载荷")
            .await?;
        let text = String::from_utf8(buf).map_err(|_| anyhow!("响应帧不是合法 UTF-8"))?;
        let value: Value = serde_json::from_str(&text).context("解析响应 JSON")?;
        Ok(value)
    }

    /// 首帧共享密钥认证（MCP-1，审计 P2-1；与 C++ 侧 `mcpCheckAuthFrame` 配对）。
    ///
    /// `BOT4CJ_MCP_TOKEN` 非空时，连接建立后的第一帧必须是
    /// `{"_route":"auth","token":...}`，通过后才能进入正常帧循环。只在
    /// `connect_timeout` 成功后、任何业务调用之前调一次。
    /// 两侧配对要求：新后端 + 旧 agent（不发 auth 帧）会被后端拒绝；旧后端 +
    /// 新 agent（发了 auth 帧）会收到 `unknown route: auth`——此函数把它翻译成
    /// 指向版本不匹配的人话，其余失败原样上抛。
    pub async fn authenticate(&mut self, token: &str) -> Result<()> {
        let resp = self
            .call(&serde_json::json!({ROUTE_FIELD: ROUTE_AUTH, TOKEN_FIELD: token}))
            .await
            .context("发送首帧认证")?;
        if resp
            .get(SUCCESS_FIELD)
            .and_then(|s| s.as_bool())
            .unwrap_or(false)
        {
            return Ok(());
        }
        let err = resp
            .get(ERROR_FIELD)
            .and_then(|e| e.as_str())
            .unwrap_or("（后端未给出原因）");
        if err.contains("unknown route") {
            bail!(
                "后端拒绝了首帧认证（{err}）——对端是不支持 BOT4CJ_MCP_TOKEN 的旧版 \
                 mybot；两侧必须同时升级或同时不设该环境变量"
            );
        }
        bail!(
            "后端拒绝了首帧认证（{err}）：共享密钥不匹配，检查两侧的 \
              BOT4CJ_MCP_TOKEN 是否一致"
        )
    }
}

/// 带整体 deadline 的 read_exact：超时与 I/O 错误同级返回 Err（连接判死）。
/// deadline 覆盖「读满整个缓冲」而不是每个字节——慢速滴流（Slowloris 形态）
/// 同样会被截断在预算内。
async fn read_exact_with_deadline(
    stream: &mut UnixStream,
    buf: &mut [u8],
    timeout: Duration,
    what: &str,
) -> Result<()> {
    match tokio::time::timeout(timeout, stream.read_exact(buf)).await {
        Ok(r) => r.context(what.to_string()).map(|_| ()),
        Err(_) => bail!(
            "{what}超时（{}s）：后端在预算内未回帧——进程可能在但不响应，\
             或工具执行超出 --llm-task-timeout 预算；连接按死处理，可重启 agent 重试",
            timeout.as_secs()
        ),
    }
}

/// 带整体 deadline 的写侧（2026-10-01 审计 P2，与上方读侧对称）：deadline 覆盖
/// 「整帧写完 + flush」。对端停止读 socket 时内核缓冲（~200 KiB）填满后
/// write_all 永久挂起——帧上限 8 MiB，模型可控的大参数帧可必现。
async fn write_with_deadline(
    stream: &mut UnixStream,
    frame: &[u8],
    timeout: Duration,
    what: &str,
) -> Result<()> {
    let written = async {
        stream.write_all(frame).await?;
        stream.flush().await
    };
    match tokio::time::timeout(timeout, written).await {
        Ok(r) => r.context(what.to_string()).map(|_| ()),
        Err(_) => bail!(
            "{what}超时（{}s）：后端在预算内没有收下请求帧——进程可能在但不读 \
             socket；连接按死处理，可重启 agent 重试",
            timeout.as_secs()
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn encode_frame_is_4byte_be_plus_payload() {
        let f = encode_frame(b"abc").unwrap();
        assert_eq!(f, vec![0, 0, 0, 3, b'a', b'b', b'c']);
        // 空载荷合法（libmsg 口径）
        assert_eq!(encode_frame(b"").unwrap(), vec![0, 0, 0, 0]);
        // 300 = 0x0000012C：多字节 BE 正确
        let big = encode_frame(&vec![b'x'; 300]).unwrap();
        assert_eq!(big.len(), 304);
        assert_eq!(&big[0..4], &[0, 0, 0x01, 0x2C]);
    }

    #[test]
    fn decode_len_roundtrips() {
        assert_eq!(decode_len(&[0, 0, 0x01, 0x2C]), 300);
        assert_eq!(decode_len(&[0xFF, 0xFF, 0xFF, 0xFF]), u32::MAX);
    }

    #[tokio::test]
    async fn call_times_out_when_backend_goes_silent() {
        // 2026-09-30 审计 P1：后端进程活着但不回帧（工具层卡死）时，此前的
        // read_exact 会无限挂起——模型侧超时与 Ctrl-C 的取消都够不到它。
        let (client_io, mut server_io) = UnixStream::pair().unwrap();
        let mut client = BackendClient::from_stream(client_io);
        client.set_read_timeout(Duration::from_millis(150));
        let server = tokio::spawn(async move {
            // 收下请求但永不回帧（卡死后端）
            let mut hdr = [0u8; 4];
            server_io.read_exact(&mut hdr).await.unwrap();
            let n = u32::from_be_bytes(hdr) as usize;
            let mut buf = vec![0u8; n];
            server_io.read_exact(&mut buf).await.unwrap();
            sleep(Duration::from_secs(30)).await;
        });
        let err = client.call(&json!({"_route": "ping"})).await.unwrap_err();
        assert!(err.to_string().contains("超时"), "实际: {err}");
        server.abort();
    }

    #[tokio::test]
    async fn call_write_times_out_when_backend_stops_reading() {
        // 2026-10-01 审计 P2：读侧修了（上一用例）、写侧漏了——后端活着但停止
        // 读 socket（同一 wedged 形态）时，超过内核 socket 缓冲（~200 KiB）的
        // write_all 无限挂起，--llm-task-timeout / HARD_READ_CEILING / Ctrl-C
        // 全都够不到这段 await。4 MiB 请求帧（< 8 MiB 上限，模型可控大参数
        // 形态）+ 假后端只收帧头就睡死 → 必然写不进去。
        let (client_io, mut server_io) = UnixStream::pair().unwrap();
        let mut client = BackendClient::from_stream(client_io);
        client.set_read_timeout(Duration::from_millis(150));
        let blob = String::from_utf8(vec![b'x'; 4 * 1024 * 1024]).unwrap();
        let req = json!({"_route": "tool.call", "arguments": blob});
        let server = tokio::spawn(async move {
            let mut hdr = [0u8; 4];
            server_io.read_exact(&mut hdr).await.unwrap();
            // 不读载荷、不回帧：客户端的 4 MiB 写必然撑爆缓冲后挂起
            sleep(Duration::from_secs(30)).await;
        });
        let err = client.call(&req).await.unwrap_err();
        assert!(err.to_string().contains("写请求帧"), "实际: {err}");
        server.abort();
    }

    #[tokio::test]
    async fn set_read_timeout_rejects_zero_and_falls_back_to_ceiling() {
        let (client_io, _server_io) = UnixStream::pair().unwrap();
        let mut client = BackendClient::from_stream(client_io);
        assert_eq!(client.read_timeout, HARD_READ_CEILING);
        // 0 = 不限任务时长 ≠ 陪后端挂到永远：回落兜底上限
        client.set_read_timeout(Duration::ZERO);
        assert_eq!(client.read_timeout, HARD_READ_CEILING);
        client.set_read_timeout(Duration::from_secs(1));
        assert_eq!(client.read_timeout, Duration::from_secs(1));
    }

    #[tokio::test]
    async fn call_roundtrips_a_frame() {
        // 假后端：读一帧、回一帧 {"success":true,"data":{"pong":true}}
        let (client_io, mut server_io) = UnixStream::pair().unwrap();
        let mut client = BackendClient::from_stream(client_io);

        let server = tokio::spawn(async move {
            let mut hdr = [0u8; 4];
            server_io.read_exact(&mut hdr).await.unwrap();
            let n = u32::from_be_bytes(hdr) as usize;
            let mut buf = vec![0u8; n];
            server_io.read_exact(&mut buf).await.unwrap();
            let req: Value = serde_json::from_slice(&buf).unwrap();
            assert_eq!(req["_route"], "ping");
            let resp =
                serde_json::to_vec(&json!({"success": true, "data": {"pong": true}})).unwrap();
            server_io
                .write_all(&encode_frame(&resp).unwrap())
                .await
                .unwrap();
        });

        let resp = client.call(&json!({"_route": "ping"})).await.unwrap();
        assert_eq!(resp["success"], true);
        assert_eq!(resp["data"]["pong"], true);
        server.await.unwrap();
    }

    #[tokio::test]
    async fn call_rejects_oversized_response_header() {
        let (client_io, mut server_io) = UnixStream::pair().unwrap();
        let mut client = BackendClient::from_stream(client_io);
        let server = tokio::spawn(async move {
            // 声称载荷 = MAX+1，但根本不发那么多——客户端应在**分配前**拒收
            let bad = (MAX_FRAME_BYTES + 1).to_be_bytes();
            server_io.write_all(&bad).await.unwrap();
        });
        let err = client.call(&json!({"_route": "ping"})).await.unwrap_err();
        assert!(err.to_string().contains("超过上限"), "实际: {err}");
        let _ = server.await;
    }

    #[tokio::test]
    async fn call_rejects_invalid_utf8_response() {
        let (client_io, mut server_io) = UnixStream::pair().unwrap();
        let mut client = BackendClient::from_stream(client_io);
        let server = tokio::spawn(async move {
            let payload: Vec<u8> = vec![0xFF, 0xFE, 0xFD]; // 非法 UTF-8
            server_io
                .write_all(&encode_frame(&payload).unwrap())
                .await
                .unwrap();
        });
        let err = client.call(&json!({"_route": "ping"})).await.unwrap_err();
        assert!(err.to_string().contains("UTF-8"), "实际: {err}");
        let _ = server.await;
    }

    #[tokio::test]
    async fn authenticate_ok_on_matching_token() {
        // 假后端：校验第一帧确是 auth 帧，回 success
        let (client_io, mut server_io) = UnixStream::pair().unwrap();
        let mut client = BackendClient::from_stream(client_io);
        let server = tokio::spawn(async move {
            let mut hdr = [0u8; 4];
            server_io.read_exact(&mut hdr).await.unwrap();
            let n = u32::from_be_bytes(hdr) as usize;
            let mut buf = vec![0u8; n];
            server_io.read_exact(&mut buf).await.unwrap();
            let req: Value = serde_json::from_slice(&buf).unwrap();
            assert_eq!(req["_route"], "auth");
            assert_eq!(req["token"], "secret-1");
            let resp =
                serde_json::to_vec(&json!({"success": true, "data": {"auth": true}})).unwrap();
            server_io
                .write_all(&encode_frame(&resp).unwrap())
                .await
                .unwrap();
        });
        client.authenticate("secret-1").await.unwrap();
        server.await.unwrap();
    }

    #[tokio::test]
    async fn authenticate_err_on_token_mismatch() {
        let (client_io, mut server_io) = UnixStream::pair().unwrap();
        let mut client = BackendClient::from_stream(client_io);
        let server = tokio::spawn(async move {
            let mut hdr = [0u8; 4];
            server_io.read_exact(&mut hdr).await.unwrap();
            let n = u32::from_be_bytes(hdr) as usize;
            let mut buf = vec![0u8; n];
            server_io.read_exact(&mut buf).await.unwrap();
            // C++ 后端拒绝口径：不区分错密钥/没带密钥
            let resp = serde_json::to_vec(&json!({
                "success": false,
                "error": "auth required: first frame must be {\"_route\":\"auth\",\"token\":...}"
            }))
            .unwrap();
            server_io
                .write_all(&encode_frame(&resp).unwrap())
                .await
                .unwrap();
        });
        let err = client.authenticate("wrong").await.unwrap_err();
        assert!(err.to_string().contains("共享密钥"), "实际: {err}");
        let _ = server.await;
    }

    #[tokio::test]
    async fn authenticate_err_hints_old_backend_on_unknown_route() {
        let (client_io, mut server_io) = UnixStream::pair().unwrap();
        let mut client = BackendClient::from_stream(client_io);
        let server = tokio::spawn(async move {
            let mut hdr = [0u8; 4];
            server_io.read_exact(&mut hdr).await.unwrap();
            let n = u32::from_be_bytes(hdr) as usize;
            let mut buf = vec![0u8; n];
            server_io.read_exact(&mut buf).await.unwrap();
            // 旧后端（不认识 auth 路由）的回执形态
            let resp =
                serde_json::to_vec(&json!({"success": false, "error": "unknown route: auth"}))
                    .unwrap();
            server_io
                .write_all(&encode_frame(&resp).unwrap())
                .await
                .unwrap();
        });
        let err = client.authenticate("secret-1").await.unwrap_err();
        assert!(err.to_string().contains("旧版"), "实际: {err}");
        let _ = server.await;
    }
}
