//! model.rs —— 模型装饰器：图片注入 + 单次调用超时 + 网络重试（U-1）
//!
//! rig 没有 completion POST 级重试（`http_client::retry` 是 SSE 事件源用的），
//! 也没有「工具结果之后的图片后注」——两者都在这一层补：
//!
//! 1. **图片注入**：C++ 把工具返回的图片作为 tool 消息**之后**的一条独立 user
//!    消息塞进历史（OpenAI 不允许工具结果里带图片）。rig 侧的等价物是把它追加到
//!    「含工具结果的那条 user 消息」的末尾——provider 转换时，同一条 user 消息里的
//!    ToolResult 先各自成 tool 消息，末尾攒下的 Text/Image 再 flush 成一条 user
//!    消息，于是线上次序正是 `[tool…, user(说明+图片)]`，与 C++ 逐位同序。
//!    注入按「第几条工具结果消息」定位（见 hook::Injection）：本任务内每次请求
//!    都重新注入，任务结束时由 REPL 物化进会话历史。
//!    **注意**：请求里的 prompt 是独立追加在历史之后的一条消息，`RequestPatch.history`
//!    碰不到它——所以图片注入必须在拿到最终请求体的这一层做，而不是钩子里。
//!
//! 2. **超时与重试**：单次调用超时（`--llm-timeout`）是**可重试**类失败；重试分类
//!    只有结构化判据：HTTP 429 = 限流（退避优先采用服务端 Retry-After）、5xx 与
//!    连接类（`http_client::Error::Instance`，含连接被拒/DNS/传输超时）= 瞬时，
//!    其余 4xx（鉴权、配额、请求本身有问题）= 不重试。这与 C++ 的 curl rc 表同口径
//!    （「重试是否可能改变结果」的判据，不是「错误严重不严重」），只是把 curl 退出码
//!    换成了 HTTP 状态码与 reqwest 错误分类——已记档为如实偏差。
//!
//! 3. **审计**：每次模型调用（含重试的尝试次数、请求体估算字节）在这里记一条，
//!    由 REPL 落 model 行。
//!
//! 4. **流式面**（`stream`）：rig 的 SSE 请求是惰性的——`inner.stream(req).await`
//!    返回 Ok 时还没发 HTTP，第一次 poll 才发；非 2xx 变成流的第一个 Err。所以
//!    这一层走 provider 的 `raw_stream` 出口：打开 → **预取首帧** → 首帧是 Err 就按
//!    与阻塞面同一张表分类重试 → 首帧 Ok 再把「首帧 + 余流」串回 rig 的
//!    `StreamingCompletionResponse`。首帧之后的中途断流**不重试**（已打给操作者
//!    的文本收不回来），直接失败。余流套一层 [`Observed`] 适配器：帧间空闲超时
//!    （`--llm-timeout` 在流式下的语义）、Ctrl-C 检查、以及流结束/出错/被丢弃时
//!    落审计 model 行——审计口径与阻塞面一致，REPL 无需知道两种面的区别。
//!    如实偏差：流式下 429 拿不到 Retry-After 头（rig 的 SSE 错误只带状态码），
//!    退避只按本地指数；预取阶段的连接类错误以 `ProviderError` 形态到达，按瞬时
//!    处理（判据：尚无字节被看到，重试不改变已见结果）。
//!
//! 5. **在飞取消**：Ctrl-C 置停止标志后，两个面都**立即丢弃在途请求**（`guard`
//!    以 `select!` 对停止标志定时轮询；流式面余流由 `Observed` 在 Pending 时检查），
//!    本轮以「请求被中断」收场——不再等服务端把整段响应吐完。

use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::{Duration, Instant};

use futures::{Stream, StreamExt};
use rig_agent::completion::message::{ImageMediaType, MimeType, UserContent};
use rig_agent::completion::{
    AssistantContent, CompletionError, CompletionModel, CompletionRequest, CompletionResponse,
    Message, ProviderCapabilities, Usage,
};
use rig_core::client::Client;
use rig_core::http_client::HttpClientExt;
use rig_core::providers::anthropic::completion::AnthropicCompatibleProvider;
use rig_core::providers::openai::completion::OpenAICompatibleProvider;
use rig_core::providers::{anthropic, openai};
// 流式响应类型在 rig-core 的 streaming 模块（completion 只重导出消息与 request 面）
use rig_core::streaming::{
    normalize_stream, RawStreamingChoice, StreamFinal, StreamingCompletionResponse, StreamingResult,
};

use crate::hook::{has_tool_result, CallRecord, HookState, Injection, IMAGE_CAPTION};
use crate::out::errln;

/// 流式适配器查取消/空闲的醒来间隔。
const STREAM_TICK_MS: u64 = 250;

/// provider 模型的「原生流」出口：rig 的 `CompletionModel::stream` 把首帧错误藏进
/// 流里，这里要的是能预取首帧再决定是否重试的形态。三族 provider 都是
/// `GenericCompletionModel<Ext, H>`，各实现一次。
pub trait RawStream {
    const PROVIDER: &'static str;
    fn raw_stream_normalized(
        &self,
        request: CompletionRequest,
    ) -> impl Future<Output = Result<StreamingResult, CompletionError>> + Send;
}

impl<Ext, H> RawStream for openai::completion::GenericCompletionModel<Ext, H>
where
    Client<Ext, H>: HttpClientExt + Clone + 'static,
    Ext: rig_core::client::Provider + OpenAICompatibleProvider + Clone + Send + Sync + 'static,
    H: Sync,
{
    const PROVIDER: &'static str = Ext::PROVIDER_NAME;
    async fn raw_stream_normalized(
        &self,
        request: CompletionRequest,
    ) -> Result<StreamingResult, CompletionError> {
        let raw = self.raw_stream(request).await?;
        Ok(normalize_stream(raw, |r| {
            Ok(StreamFinal::from((Ext::PROVIDER_NAME, r)))
        }))
    }
}

impl<Ext, T> RawStream for anthropic::completion::GenericCompletionModel<Ext, T>
where
    T: HttpClientExt + Clone + Default + 'static,
    Ext: AnthropicCompatibleProvider + Clone + Send + Sync + 'static,
{
    const PROVIDER: &'static str = Ext::PROVIDER_NAME;
    async fn raw_stream_normalized(
        &self,
        request: CompletionRequest,
    ) -> Result<StreamingResult, CompletionError> {
        let raw = self.raw_stream(request).await?;
        Ok(normalize_stream(raw, |r| {
            Ok(StreamFinal::from((Ext::PROVIDER_NAME, r)))
        }))
    }
}

/// 单次退避上限（毫秒）——与 C++ `llm_limits::kRetryBackoffCapMs` 逐值对齐。
pub const RETRY_BACKOFF_CAP_MS: u64 = 60_000;
/// 服务端 Retry-After 的钳制区间（毫秒）——与 C++ `kRetryAfterMinMs/MaxMs` 逐值对齐。
pub const RETRY_AFTER_MIN_MS: u64 = 1_000;
pub const RETRY_AFTER_MAX_MS: u64 = 5 * 60 * 1000;

/// 单次调用超时的错误标记：只有它（而不是所有 RequestError）属于可重试类，
/// 免得「工具表取不到」这类请求构造期错误也被退避重试。
#[derive(Debug)]
struct ModelTimeout {
    seconds: i64,
}

impl std::fmt::Display for ModelTimeout {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "模型调用超时（{} 秒；--llm-timeout / 配置文件的 timeout）",
            self.seconds
        )
    }
}

impl std::error::Error for ModelTimeout {}

#[derive(Debug)]
struct Interrupted;

impl std::fmt::Display for Interrupted {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // 逐字同 C++ agentdriver.cpp 的中断文案
        write!(f, "请求被中断")
    }
}

impl std::error::Error for Interrupted {}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RetryClass {
    /// 别再试了：4xx（429 除外）、请求本身有问题
    No,
    /// 稍后再试：连接类失败、5xx、单次调用超时
    Transient,
    /// 被限流：429 —— 退避优先采用服务端给的 Retry-After
    Throttled,
}

struct Classified {
    class: RetryClass,
    retry_after_ms: u64,
    message: String,
}

/// 错误分类（纯函数、不碰网络，可离线穷举）。
fn classify(e: &CompletionError) -> Classified {
    let mut retry_after_ms = 0u64;
    if let Some(headers) = e.provider_response_headers() {
        if let Some(v) = headers.get("retry-after").and_then(|v| v.to_str().ok()) {
            if let Ok(secs) = v.trim().parse::<u64>() {
                retry_after_ms = (secs * 1000).clamp(RETRY_AFTER_MIN_MS, RETRY_AFTER_MAX_MS);
            }
        }
    }
    let class = match e.provider_response_status() {
        // 429 是「限流」而不是普通瞬时错误：退避要尊重服务端的 Retry-After
        Some(s) if s.as_u16() == 429 => RetryClass::Throttled,
        Some(s) if s.is_server_error() => RetryClass::Transient,
        Some(_) => RetryClass::No,
        None => match e {
            // 连接被拒 / DNS / 传输中断 / 传输超时（reqwest 侧）
            CompletionError::HttpError(rig_core::http_client::Error::Instance(_)) => {
                RetryClass::Transient
            }
            CompletionError::RequestError(inner)
                if inner.downcast_ref::<ModelTimeout>().is_some() =>
            {
                RetryClass::Transient
            }
            _ => RetryClass::No,
        },
    };
    Classified {
        class,
        retry_after_ms,
        message: e.to_string(),
    }
}

/// 模型装饰器：把 rig 的内置 provider 模型包一层。
pub struct BudgetModel<M> {
    inner: M,
    state: Arc<HookState>,
    /// 单次调用超时（秒；<=0 = 不限）
    timeout_sec: i64,
    /// 尝试次数**含首次**（= max(1, max_retries)）
    max_attempts: u64,
    retry_backoff_ms: u64,
}

impl<M: CompletionModel> BudgetModel<M> {
    pub fn new(
        inner: M,
        state: Arc<HookState>,
        timeout_sec: i64,
        max_retries: i64,
        retry_backoff_ms: i64,
    ) -> Self {
        Self {
            inner,
            state,
            timeout_sec,
            // 钳到 ≥1：max_retries 是「含首次的尝试次数」而配置文件允许 0（= 不重试），
            // 直接拿 0 当上界会「一次都不发」——「不重试」仍然是发一次（同 C++）。
            max_attempts: std::cmp::max(1, max_retries) as u64,
            retry_backoff_ms: retry_backoff_ms.max(0) as u64,
        }
    }

    /// 把桥收集到的图片注入本次请求（见模块头第 1 条）。
    fn inject_images(&self, request: &mut CompletionRequest) -> Result<(), CompletionError> {
        let fresh = self.state.take_pending_images();
        if !fresh.is_empty() {
            let ordinal = request
                .chat_history
                .iter()
                .filter(|m| has_tool_result(m))
                .count();
            if ordinal == 0 {
                // 不静默：图片确实没进上下文，操作者必须看得见
                errln!(
                    "[mybot-agent] 警告: 工具返回了 {} 张图片（共 {} 字节 data URL），\
                     但本次请求里没有可挂载的工具结果消息，本批图片**未**注入对话。",
                    fresh.len(),
                    fresh.iter().map(|s| s.len()).sum::<usize>()
                );
            } else {
                let mut content = Vec::with_capacity(fresh.len() + 1);
                content.push(UserContent::text(IMAGE_CAPTION));
                // data URL 必须拆成内联图片，否则 Anthropic 会把它当成待下载的 URL。
                for url in fresh {
                    content.push(image_from_data_url(&url)?);
                }
                self.state.push_injection(Injection { ordinal, content });
            }
        }
        apply_injections(&mut request.chat_history, &self.state.injections());
        Ok(())
    }

    /// 一次尝试：单次调用超时是可重试类失败；在飞期间 Ctrl-C 立即放弃（见 [`Self::guard`]）。
    async fn attempt(
        &self,
        request: CompletionRequest,
    ) -> Result<CompletionResponse, CompletionError> {
        self.guard(self.inner.completion(request)).await
    }

    /// 给一次在飞的模型调用套上两道观测：单次调用超时（`--llm-timeout`，<=0 不限）
    /// 与停止标志（Ctrl-C）。两者都以**丢弃 future** 的方式中止在途请求——HTTP
    /// 客户端随之断连，不等服务端把整段响应吐完。
    async fn guard<T>(
        &self,
        fut: impl Future<Output = Result<T, CompletionError>>,
    ) -> Result<T, CompletionError> {
        let stop_requested = async {
            let mut tick = tokio::time::interval(Duration::from_millis(STREAM_TICK_MS));
            loop {
                tick.tick().await;
                if self.state.stop.load(Ordering::Relaxed) {
                    return;
                }
            }
        };
        let guarded = async {
            tokio::select! {
                r = fut => r,
                _ = stop_requested => Err(CompletionError::RequestError(Box::new(Interrupted))),
            }
        };
        if self.timeout_sec > 0 {
            match tokio::time::timeout(Duration::from_secs(self.timeout_sec as u64), guarded).await
            {
                Ok(r) => r,
                Err(_) => Err(CompletionError::RequestError(Box::new(ModelTimeout {
                    seconds: self.timeout_sec,
                }))),
            }
        } else {
            guarded.await
        }
    }

    /// 退避并打日志（文案与 C++ `backoffAndLog` 逐字一致）。
    async fn backoff_and_log(&self, c: &Classified, attempt: u64) {
        // 本地指数退避：base × 2^(attempt-1)（attempt 从 1 数起，首次重试就是 base），
        // 单次钳到 kRetryBackoffCapMs —— 与 C++ `backoffAndLog` 同式同钳。
        let shift = attempt.saturating_sub(1).min(20);
        let local_ms = self
            .retry_backoff_ms
            .saturating_mul(1u64 << shift)
            .min(RETRY_BACKOFF_CAP_MS);
        let mut delay_ms = local_ms;
        let mut source = "本地指数退避";
        if c.retry_after_ms > 0 && c.retry_after_ms > delay_ms {
            delay_ms = c.retry_after_ms;
            source = "服务端 Retry-After";
        }
        let what = if c.class == RetryClass::Throttled {
            "限流"
        } else {
            "网络错误"
        };
        errln!(
            "[agent] {what}，{delay_ms}ms 后重试（{attempt}/{attempts}，退避来源: {source}）: {message}",
            attempts = self.max_attempts,
            message = c.message
        );
        // 退避期间 Ctrl-C 同样即时生效（调用方在返回后复查停止标志）
        let deadline = tokio::time::sleep(Duration::from_millis(delay_ms));
        tokio::pin!(deadline);
        let mut tick = tokio::time::interval(Duration::from_millis(STREAM_TICK_MS));
        loop {
            tokio::select! {
                _ = &mut deadline => return,
                _ = tick.tick() => {
                    if self.state.stop.load(Ordering::Relaxed) {
                        return;
                    }
                }
            }
        }
    }

    fn record(
        &self,
        turn: usize,
        req_bytes: u64,
        resp_bytes: u64,
        attempts: u64,
        started: Instant,
        res: Result<&CompletionResponse, &CompletionError>,
    ) {
        let rec = match res {
            Ok(resp) => call_record(
                turn,
                req_bytes,
                resp_bytes,
                attempts,
                started,
                Ok(resp.usage),
            ),
            Err(e) => call_record(turn, req_bytes, 0, attempts, started, Err(e.to_string())),
        };
        self.state.record_call(rec);
    }
}

/// 一条模型调用观测值（阻塞面与流式面共用）。`Ok(usage)`：provider 给的用量
/// **只记不推算**（0 = provider 没给）。
fn call_record(
    turn: usize,
    req_bytes: u64,
    resp_bytes: u64,
    attempts: u64,
    started: Instant,
    res: Result<Usage, String>,
) -> CallRecord {
    let mut rec = CallRecord {
        turn,
        req_bytes,
        resp_bytes,
        attempts,
        ms: started.elapsed().as_millis().min(i64::MAX as u128) as i64,
        ..Default::default()
    };
    match res {
        Ok(u) => {
            rec.ok = true;
            rec.prompt_tokens = (u.input_tokens > 0).then_some(u.input_tokens as i64);
            rec.completion_tokens = (u.output_tokens > 0).then_some(u.output_tokens as i64);
        }
        Err(e) => rec.error = e,
    }
    rec
}

/// 首帧之后的余流适配器：观测 + 帧间空闲超时 + 取消 + 审计落行（见模块头第 4 条）。
///
/// 审计行在流**结束**（None）、**出错**（Err，含本层产生的超时/中断）或**被丢弃**
/// （Drop）时落一次；三者互斥（`rec` 取走即标记已落）。被丢弃时若已收到 provider
/// 的终帧（usage 到手）视为成功——rig 的 runner 拿到终帧后可能不再 poll 到 None。
struct Observed {
    inner: StreamingResult,
    state: Arc<HookState>,
    /// `Some` = 尚未落审计行；取走即落
    pending: Option<(usize, u64, u64, Instant)>,
    resp_bytes: u64,
    usage: Option<Usage>,
    idle_limit: Option<Duration>,
    last_item: Instant,
    tick: tokio::time::Interval,
}

impl Observed {
    fn new(
        inner: StreamingResult,
        state: Arc<HookState>,
        turn: usize,
        req_bytes: u64,
        attempts: u64,
        started: Instant,
        timeout_sec: i64,
    ) -> Self {
        let mut tick = tokio::time::interval(Duration::from_millis(STREAM_TICK_MS));
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        Self {
            inner,
            state,
            pending: Some((turn, req_bytes, attempts, started)),
            resp_bytes: 0,
            usage: None,
            idle_limit: (timeout_sec > 0).then(|| Duration::from_secs(timeout_sec as u64)),
            last_item: Instant::now(),
            tick,
        }
    }

    fn finish(&mut self, res: Result<(), String>) {
        let Some((turn, req_bytes, attempts, started)) = self.pending.take() else {
            return;
        };
        let res = match res {
            Ok(()) => Ok(self.usage.unwrap_or_default()),
            Err(e) => Err(e),
        };
        self.state.record_call(call_record(
            turn,
            req_bytes,
            self.resp_bytes,
            attempts,
            started,
            res,
        ));
    }

    fn fail(&mut self, e: CompletionError) -> Poll<Option<<Self as Stream>::Item>> {
        self.finish(Err(e.to_string()));
        Poll::Ready(Some(Err(e)))
    }
}

impl Stream for Observed {
    type Item = Result<RawStreamingChoice<StreamFinal>, CompletionError>;

    fn poll_next(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        let this = self.get_mut();
        if this.pending.is_none() {
            return Poll::Ready(None);
        }
        match this.inner.as_mut().poll_next(cx) {
            Poll::Ready(Some(Ok(item))) => {
                this.last_item = Instant::now();
                match &item {
                    RawStreamingChoice::Message(t) => this.resp_bytes += t.len() as u64,
                    RawStreamingChoice::FinalResponse(f) => this.usage = Some(f.usage),
                    _ => {}
                }
                Poll::Ready(Some(Ok(item)))
            }
            Poll::Ready(Some(Err(e))) => this.fail(e),
            Poll::Ready(None) => {
                this.finish(Ok(()));
                Poll::Ready(None)
            }
            Poll::Pending => {
                // 定时醒来：Ctrl-C 与帧间空闲都不会由 inner 唤醒，得自己挂一个 waker
                while this.tick.poll_tick(cx).is_ready() {}
                if this.state.stop.load(Ordering::Relaxed) {
                    return this.fail(CompletionError::RequestError(Box::new(Interrupted)));
                }
                if let Some(limit) = this.idle_limit {
                    if this.last_item.elapsed() >= limit {
                        return this.fail(CompletionError::RequestError(Box::new(ModelTimeout {
                            seconds: limit.as_secs() as i64,
                        })));
                    }
                }
                Poll::Pending
            }
        }
    }
}

impl Drop for Observed {
    fn drop(&mut self) {
        if self.usage.is_some() {
            self.finish(Ok(()));
        } else {
            self.finish(Err("流在完成前被丢弃".to_string()));
        }
    }
}

fn image_from_data_url(url: &str) -> Result<UserContent, CompletionError> {
    let (mime, data) = url
        .strip_prefix("data:")
        .and_then(|s| s.split_once(";base64,"))
        .ok_or_else(|| CompletionError::RequestError("后端图片不是 base64 data URL".into()))?;
    let media_type = ImageMediaType::from_mime_type(mime)
        .ok_or_else(|| CompletionError::RequestError("后端图片 MIME 类型无效".into()))?;
    Ok(UserContent::image_base64(data, Some(media_type), None))
}

/// 把已注入的批次各自追加到对应序号的工具结果消息末尾。
/// 序号在「本轮请求的历史」上从头数（外层 seed + 本轮消息），与前缀稳定对应。
fn apply_injections(history: &mut [Message], injections: &[Injection]) {
    for inj in injections {
        let mut count = 0usize;
        for m in history.iter_mut() {
            if !has_tool_result(m) {
                continue;
            }
            count += 1;
            if count == inj.ordinal {
                if let Message::User { content } = m {
                    content.extend(inj.content.iter().cloned());
                }
                break;
            }
        }
    }
}

impl<M> CompletionModel for BudgetModel<M>
where
    M: CompletionModel + RawStream + Send + Sync,
{
    async fn completion(
        &self,
        mut request: CompletionRequest,
    ) -> Result<CompletionResponse, CompletionError> {
        self.inject_images(&mut request)?;
        // SAN-9：请求体估算字节——**按段求和**，不整份序列化再丢弃。旧实现
        // `serde_json::to_vec(&request)` 把含 base64 图片的完整请求体序列化
        // 一遍只为拿长度：每轮一次 O(历史) 的 CPU/内存峰值，与「图片峰值内存
        // 数十倍」的已知痛点同向放大。口径与 C++ 的 messageWeight 同源
        // （history::message_weight 的下界：只计正文/调用参数/图片/思维链，
        // 不计 JSON 语法开销与转义膨胀），另计每次随行的 preamble 与工具 schema。
        let req_bytes = request_bytes_lower_bound(&request);
        let turn = self.state.current_turn.load(Ordering::Relaxed);
        let started = Instant::now();
        let (resp, attempt) = self
            .retry_open(
                &request,
                turn,
                req_bytes,
                started,
                |_, c| c,
                |req| self.attempt(req),
            )
            .await?;
        let resp_bytes = response_text_bytes(&resp);
        self.record(turn, req_bytes, resp_bytes, attempt, started, Ok(&resp));
        Ok(resp)
    }

    /// 流式面：图片注入与阻塞面一致；打开 + 预取首帧 + 按同一张表重试；余流套
    /// [`Observed`]（空闲超时/取消/审计）。见模块头第 4 条。
    async fn stream(
        &self,
        mut request: CompletionRequest,
    ) -> Result<StreamingCompletionResponse, CompletionError> {
        self.inject_images(&mut request)?;
        let req_bytes = request_bytes_lower_bound(&request);
        let turn = self.state.current_turn.load(Ordering::Relaxed);
        let started = Instant::now();
        // 预取阶段的 ProviderError = 连接类失败被 rig 的 SSE 传输层抹成了字符串
        // （见模块头第 4 条）；此时尚无字节被看到，按瞬时处理——经 adjust 传入
        // 骨架，与阻塞面的分类差异只在此处表达。
        let (primed, attempt) = self
            .retry_open(
                &request,
                turn,
                req_bytes,
                started,
                |e, mut c| {
                    if c.class == RetryClass::No && matches!(e, CompletionError::ProviderError(_)) {
                        c.class = RetryClass::Transient;
                    }
                    c
                },
                |req| self.open_primed(req),
            )
            .await?;
        let observed = Observed::new(
            primed,
            Arc::clone(&self.state),
            turn,
            req_bytes,
            attempt,
            started,
            self.timeout_sec,
        );
        Ok(StreamingCompletionResponse::stream(
            M::PROVIDER,
            Box::pin(observed),
        ))
    }

    fn capabilities(&self) -> ProviderCapabilities {
        self.inner.capabilities()
    }
}

impl<M: CompletionModel + RawStream> BudgetModel<M> {
    /// 阻塞（completion）与流式（stream）两条面共用的重试骨架（2026-10-01
    /// 合一，此前是两份近复制的循环）：stop 前置检查（D4：Ctrl-C 后不再发起
    /// 新的模型轮）→ attempt++ → open → 错误分类（classify 后经 adjust 修正）
    /// → No/耗尽即记错返回 → 退避 → 二次 stop 检查（退避期间可能 Ctrl-C）。
    /// Ok 返回 (产物, 实际尝试次数)；**Ok 侧的 record 留给调用方**——阻塞面
    /// 要记响应文本字节，流式面由 Observed 在流结束时代记，两边记账口径不同。
    async fn retry_open<T, F, Fut>(
        &self,
        request: &CompletionRequest,
        turn: usize,
        req_bytes: u64,
        started: Instant,
        adjust: impl Fn(&CompletionError, Classified) -> Classified,
        mut open: F,
    ) -> Result<(T, u64), CompletionError>
    where
        F: FnMut(CompletionRequest) -> Fut,
        Fut: std::future::Future<Output = Result<T, CompletionError>>,
    {
        let mut attempt = 0u64;
        loop {
            if self.state.stop.load(Ordering::Relaxed) {
                let e = CompletionError::RequestError(Box::new(Interrupted));
                self.record(turn, req_bytes, 0, attempt.max(1), started, Err(&e));
                return Err(e);
            }
            attempt += 1;
            match open(request.clone()).await {
                Ok(x) => return Ok((x, attempt)),
                Err(e) => {
                    let c = adjust(&e, classify(&e));
                    if c.class == RetryClass::No || attempt >= self.max_attempts {
                        self.record(turn, req_bytes, 0, attempt, started, Err(&e));
                        return Err(e);
                    }
                    self.backoff_and_log(&c, attempt).await;
                    if self.state.stop.load(Ordering::Relaxed) {
                        let e = CompletionError::RequestError(Box::new(Interrupted));
                        self.record(turn, req_bytes, 0, attempt, started, Err(&e));
                        return Err(e);
                    }
                }
            }
        }
    }

    /// 打开原生流并预取首帧（整体受 [`Self::guard`] 约束：单次调用超时 + Ctrl-C）：
    /// 首帧 Ok 才算「连上了」，返回「首帧 + 余流」；首帧 Err / 首帧前结束 / 超时 /
    /// 中断都作为可分类的错误返回。
    async fn open_primed(
        &self,
        request: CompletionRequest,
    ) -> Result<StreamingResult, CompletionError> {
        self.guard(async {
            let mut s = self.inner.raw_stream_normalized(request).await?;
            match s.next().await {
                Some(Ok(first)) => {
                    let primed: StreamingResult =
                        Box::pin(futures::stream::once(async move { Ok(first) }).chain(s));
                    Ok(primed)
                }
                Some(Err(e)) => Err(e),
                None => Err(CompletionError::ProviderError(
                    "流在首帧前结束（服务端未发任何事件）".to_string(),
                )),
            }
        })
        .await
    }
}

/// 请求体线上体积的**下界**估算：preamble + 历史消息（message_weight 同口径）
/// + 工具 schema（名字/描述/参数 JSON），不计 JSON 语法开销与转义膨胀。
///
/// SAN-9 的求和估算（口径见调用点注释）。
fn request_bytes_lower_bound(req: &CompletionRequest) -> u64 {
    let mut n = req.preamble.as_ref().map_or(0, |s| s.len());
    for m in &req.chat_history {
        n += crate::history::message_weight(m);
    }
    for t in &req.tools {
        n += t.name.len()
            + t.description.len()
            + serde_json::to_string(&t.parameters).map_or(0, |s| s.len());
    }
    n as u64
}

/// 响应里**模型可见文本**的字节数（C++ 记的是 `resp.content.size()`——
/// 只算文本，不算工具调用参数；工具调用轮次的响应文本常为空，此时该字段缺省不写）。
fn response_text_bytes(resp: &CompletionResponse) -> u64 {
    resp.choice
        .iter()
        .map(|c| match c {
            AssistantContent::Text(t) => t.text.len() as u64,
            _ => 0,
        })
        .sum()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::budget::TaskBudget;
    use rig_agent::completion::message::ToolResultContent;

    fn state() -> Arc<HookState> {
        Arc::new(HookState::new(900, 16, TaskBudget::new(0, 0, 0)))
    }

    fn tool_result_msg(id: &str) -> Message {
        Message::User {
            content: vec![UserContent::tool_result(
                id,
                "capture_image",
                vec![ToolResultContent::Text("ok".to_string().into())],
            )],
        }
    }

    /// 图片必须追加到「含工具结果的那条消息」末尾：provider 转换后才会落在
    /// tool 消息之后（与 C++ 的图片后注同序）。
    #[test]
    fn images_are_appended_to_the_tool_result_message() {
        let st = state();
        // 上一轮的工具结果 + 本轮的 prompt（rig 的 prompt 是独立追加的最后一条）
        let mut history = vec![
            Message::user("任务一"),
            tool_result_msg("call_0"),
            Message::user("任务二"),
        ];
        st.push_image("data:image/png;base64,AAAA".to_string());
        let fresh = st.take_pending_images();
        let mut content = vec![UserContent::text(IMAGE_CAPTION)];
        for url in fresh {
            content.push(image_from_data_url(&url).unwrap());
        }
        st.push_injection(Injection {
            ordinal: 1,
            content,
        });
        apply_injections(&mut history, &st.injections());

        let Message::User { content } = &history[1] else {
            panic!("第 1 条是工具结果消息");
        };
        assert_eq!(content.len(), 3, "工具结果 + 说明 + 图片");
        assert!(matches!(content[0], UserContent::ToolResult(_)));
        assert!(matches!(&content[1], UserContent::Text(t) if t.text == IMAGE_CAPTION));
        assert!(matches!(&content[2], UserContent::Image(_)));
        // 本轮 prompt（任务二）不受影响：图片挂在工具结果那条上，不会插到 prompt 之前
        assert_eq!(history[2], Message::user("任务二"));
    }

    #[test]
    fn data_urls_become_inline_images_without_reencoding() {
        use rig_agent::completion::message::{DocumentSourceKind, ImageMediaType};
        for (mime, expected) in [
            ("image/jpeg", ImageMediaType::JPEG),
            ("image/png", ImageMediaType::PNG),
        ] {
            let UserContent::Image(image) =
                image_from_data_url(&format!("data:{mime};base64,AAAA")).unwrap()
            else {
                panic!("expected image");
            };
            assert_eq!(image.data, DocumentSourceKind::Base64("AAAA".into()));
            assert_eq!(image.media_type, Some(expected));
        }
        for invalid in [
            "https://example.com/image.jpg",
            "data:image/jpeg,AAAA",
            "data:text/plain;base64,AAAA",
        ] {
            assert!(image_from_data_url(invalid).is_err());
        }
    }

    #[test]
    fn injections_land_on_their_own_round_not_the_newest() {
        let history_src = vec![
            Message::user("任务一"),
            tool_result_msg("call_0"),
            Message::assistant("一"),
            Message::user("任务二"),
            tool_result_msg("call_1"),
            Message::user("任务三"),
        ];
        let injections = vec![
            Injection {
                ordinal: 2,
                content: vec![UserContent::text("批二")],
            },
            Injection {
                ordinal: 1,
                content: vec![UserContent::text("批一")],
            },
        ];
        let mut history = history_src;
        apply_injections(&mut history, &injections);
        // 注入是「追加到原消息里」，不新增消息：条数与次序都不变
        assert_eq!(history.len(), 6);
        assert!(matches!(history[2], Message::Assistant { .. }));
        assert!(matches!(&history[1], Message::User { content }
            if matches!(&content[1], UserContent::Text(t) if t.text == "批一")));
        assert!(matches!(&history[4], Message::User { content }
            if matches!(&content[1], UserContent::Text(t) if t.text == "批二")));
        // 本轮的 prompt（任务三）不动：图片只挂在各自那轮的工具结果上
        assert_eq!(history[5], Message::user("任务三"));
    }

    #[test]
    fn retry_classification_follows_status_then_transport() {
        use rig_core::http_client;
        // 429 → 限流；退避采用 Retry-After
        let mut headers = http_client::HeaderMap::new();
        headers.insert("retry-after", "30".parse().unwrap());
        let e = CompletionError::from_http_response(
            http::StatusCode::TOO_MANY_REQUESTS,
            "rate limited",
        )
        .with_response_headers(Some(Box::new(headers)));
        let c = classify(&e);
        assert_eq!(c.class, RetryClass::Throttled);
        assert_eq!(c.retry_after_ms, 30_000);
        // 5xx → 瞬时；429 以外的 4xx → 不重试（与 C++ 同口径：重试改变不了结果）
        for (status, want) in [
            (
                http::StatusCode::INTERNAL_SERVER_ERROR,
                RetryClass::Transient,
            ),
            (http::StatusCode::BAD_GATEWAY, RetryClass::Transient),
            (http::StatusCode::UNAUTHORIZED, RetryClass::No),
            (http::StatusCode::BAD_REQUEST, RetryClass::No),
        ] {
            assert_eq!(
                classify(&CompletionError::from_http_response(status, "x")).class,
                want,
                "状态码 {status} 判类错"
            );
        }
        // 连接类（reqwest 错误）→ 瞬时
        let io =
            http_client::Error::Instance(Box::new(std::io::Error::other("connection refused")));
        assert_eq!(
            classify(&CompletionError::HttpError(io)).class,
            RetryClass::Transient
        );
        // 单次调用超时 → 瞬时；其余请求构造错误 → 不重试
        assert_eq!(
            classify(&CompletionError::RequestError(Box::new(ModelTimeout {
                seconds: 1
            })))
            .class,
            RetryClass::Transient
        );
        assert_eq!(
            classify(&CompletionError::RequestError("工具表取不到".into())).class,
            RetryClass::No
        );
        assert_eq!(
            classify(&CompletionError::ProviderError("boom".to_string())).class,
            RetryClass::No
        );
    }

    #[test]
    fn retry_after_below_minimum_is_clamped() {
        use rig_core::http_client;
        let mut headers = http_client::HeaderMap::new();
        headers.insert("retry-after", "0".parse().unwrap());
        let e = CompletionError::from_http_response(http::StatusCode::TOO_MANY_REQUESTS, "x")
            .with_response_headers(Some(Box::new(headers)));
        assert_eq!(classify(&e).retry_after_ms, RETRY_AFTER_MIN_MS);
        // 天文数字被钳到上限（坏网关不能把 agent 挂死一天）
        let mut headers = http_client::HeaderMap::new();
        headers.insert("retry-after", "999999".parse().unwrap());
        let e = CompletionError::from_http_response(http::StatusCode::TOO_MANY_REQUESTS, "x")
            .with_response_headers(Some(Box::new(headers)));
        assert_eq!(classify(&e).retry_after_ms, RETRY_AFTER_MAX_MS);
    }

    #[test]
    fn response_text_bytes_counts_only_text() {
        let resp = CompletionResponse::new(
            vec![
                AssistantContent::text("你好"),
                AssistantContent::ToolCall(rig_agent::completion::message::ToolCall::new(
                    rig_agent::completion::message::ToolCallId::new_or_mint("call_0"),
                    rig_agent::completion::message::ToolFunction::new(
                        "t".to_string(),
                        serde_json::json!({"a": 1}),
                    ),
                )),
            ],
            rig_agent::completion::Usage::new(),
            "test",
        );
        assert_eq!(response_text_bytes(&resp), "你好".len() as u64);
    }
}
