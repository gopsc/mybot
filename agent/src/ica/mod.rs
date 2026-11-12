//! ICA experimental evidence ledger for the Rust agent. Observations are records of
//! inputs/results, never automatic facts. Model tools cannot verify a claim.
//!
//! 2026-09-29 B1 拆分：账本核心（本文件）／工具 schema（specs.rs）／sidecar
//! 持久化（persist.rs）三个文件；`execute` 的八个工具分支各成私有方法。

mod persist;
mod specs;

pub use specs::specs;

use std::collections::HashSet;
use std::sync::Arc;
use std::sync::Mutex as StdMutex;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::hook::poisoned;
use crate::toolspec::ToolSpec;

#[derive(Clone, Serialize, Deserialize)]
struct Event {
    id: String,
    source_type: String,
    origin_id: String,
    content: String,
    retracted: bool,
}

#[derive(Clone, Serialize, Deserialize)]
struct Claim {
    id: String,
    text: String,
    scope: String,
    state: String,
}

#[derive(Clone, Serialize, Deserialize)]
struct Evidence {
    id: String,
    claim_id: String,
    event_id: String,
    supports: bool,
    active: bool,
}

#[derive(Clone, Serialize, Deserialize)]
struct FutureItem {
    id: String,
    kind: String,
    text: String,
    predicted_observation: String,
    state: String,
    #[serde(default)]
    task_id: u64,
    #[serde(default)]
    created_after_event: usize,
    #[serde(default)]
    tool: String,
    #[serde(default)]
    arguments: Value,
    #[serde(default)]
    result_event_id: String,
}

#[derive(Clone, Serialize, Deserialize)]
struct Comparison {
    id: String,
    future_id: String,
    event_id: String,
    possible_match: bool,
    active: bool,
}

/// ICA 会话门面：BOT4CJ_ICA 开关读取、账本持有与观察/落盘/恢复。
/// 2026-10-01 自 bridge.rs 收边（行为保持）——启停判据与账本生命周期归本模块
/// 单点，bridge 只在工具清单合并与 ica_* 派发处取用；repl/main 经
/// `bridge.ica` 使用。锁中毒统一走 hook::poisoned（带 warn 留痕）。
pub struct IcaSession {
    ledger: Option<Arc<StdMutex<IcaLedger>>>,
}

impl IcaSession {
    /// BOT4CJ_ICA=1 时启用（缺省不启用）。
    pub fn from_env() -> Self {
        Self {
            ledger: (std::env::var("BOT4CJ_ICA").as_deref() == Ok("1"))
                .then(|| Arc::new(StdMutex::new(IcaLedger::default()))),
        }
    }

    pub fn enabled(&self) -> bool {
        self.ledger.is_some()
    }

    /// 账本句柄（ica_* 工具派发用）；未启用时 None。
    pub fn ledger(&self) -> Option<&Arc<StdMutex<IcaLedger>>> {
        self.ledger.as_ref()
    }

    pub fn observe_user(&self, task: &str) {
        if let Some(ica) = &self.ledger {
            let mut ledger = ica.lock().unwrap_or_else(poisoned);
            ledger.begin_task(task);
        }
    }

    pub fn note(&self) -> Option<String> {
        self.ledger
            .as_ref()
            .map(|ica| ica.lock().unwrap_or_else(poisoned).final_note())
    }

    pub fn summary(&self) -> Option<String> {
        self.ledger
            .as_ref()
            .map(|ica| ica.lock().unwrap_or_else(poisoned).summary())
    }

    pub fn clear(&self) {
        if let Some(ica) = &self.ledger {
            *ica.lock().unwrap_or_else(poisoned) = IcaLedger::default();
        }
    }

    pub fn save(&self, session_file: &str) -> Result<(), String> {
        if let Some(ica) = &self.ledger {
            ica.lock().unwrap_or_else(poisoned).save(session_file)?;
        }
        Ok(())
    }

    pub fn restore(&self, session_file: &str) -> Result<(), String> {
        if let Some(ica) = &self.ledger {
            *ica.lock().unwrap_or_else(poisoned) = IcaLedger::load(session_file)?;
        }
        Ok(())
    }

    /// 工具清单合并：启用时把 ica_* 的 schema 并进 specs，与后端工具名冲突即报错。
    pub fn merge_specs(&self, specs: &mut Vec<ToolSpec>) -> Result<(), String> {
        if self.ledger.is_some() {
            let ica_specs = crate::ica::specs();
            if ica_specs
                .iter()
                .any(|i| specs.iter().any(|s| s.name == i.name))
            {
                return Err("后端工具名与 ICA 工具名冲突".into());
            }
            specs.extend(ica_specs);
        }
        Ok(())
    }
}

#[derive(Default, Serialize, Deserialize)]
pub struct IcaLedger {
    #[serde(default)]
    current_task: u64,
    events: Vec<Event>,
    claims: Vec<Claim>,
    evidence: Vec<Evidence>,
    futures: Vec<FutureItem>,
    comparisons: Vec<Comparison>,
    dependencies: Vec<(String, String)>,
}

fn required<'a>(args: &'a Value, key: &str) -> Result<&'a str, String> {
    args.get(key)
        .and_then(Value::as_str)
        .filter(|s| !s.trim().is_empty())
        .ok_or_else(|| format!("ICA 缺少字符串字段 {key}"))
}

fn limit_content(s: &str) -> String {
    s.chars().take(8192).collect()
}

/// 开启 ICA 时追加进系统提示词的行为约束段（2026-09-29 B2 归位自 main.rs，
/// 文本逐字保持）。
pub fn preamble_section() -> &'static str {
    "\n## ICA 实验性证据层\n用户输入与工具回执先登记为观察，不自动成为事实。\
     需要陈述可核验事实时，用 ICA 工具登记主张、引用观察和未来候选；\
     这些工具不能验证主张，也不会自动执行行动。相同工具名的回执保守地视为同一来源。\
     对机器人现实动作，先用只读工具检查当前状态，再调用 ica_propose_action 登记完整工具参数、理由和预期可观察结果，\
     然后才调用对应动作工具。动作回执返回后用 ica_compare_future 对比预测；若未达预期，应说明差异并修订。\
     在资料不足、没有适用工具时保留未知缺口，不要伪造验证。创作任务无需事实验证。\n"
}

impl IcaLedger {
    pub fn begin_task(&mut self, task: &str) {
        self.current_task += 1;
        self.observe("user", "user", task);
    }

    fn action_tool(name: &str) -> bool {
        matches!(name, "run_action_script" | "apply_sql" | "run_command")
    }

    fn has_current_inspection(&self) -> bool {
        self.events.iter().skip(self.task_start_event()).any(|e| {
            e.source_type == "tool"
                && !e.retracted
                && matches!(
                    e.origin_id.as_str(),
                    "list_hardware" | "query_sql" | "read_variables"
                )
        })
    }

    pub fn authorize_action(&self, name: &str, arguments: &Value) -> Result<String, String> {
        if !Self::action_tool(name) {
            return Ok(String::new());
        }
        if !self.has_current_inspection() {
            return Err("ICA 现实检查：本任务尚未读取机器人状态。请先调用 list_hardware、query_sql 或 read_variables。动作未执行。".into());
        }
        if self.futures.iter().any(|f| {
            f.kind == "action_proposal"
                && f.task_id == self.current_task
                && !f.result_event_id.is_empty()
        }) {
            return Err("ICA 校准门：本任务已有现实动作。执行回执不等于目标状态；没有可信的动作后传感器核对，拒绝连续派发第二个动作。请检查实际状态并重新建立任务。".into());
        }
        self.futures
            .iter()
            .rev()
            .find(|f| {
                f.kind == "action_proposal"
                    && f.task_id == self.current_task
                    && f.tool == name
                    && f.arguments == *arguments
                    && f.state == "proposed"
                    && !f.predicted_observation.trim().is_empty()
            })
            .map(|f| f.id.clone())
            .ok_or_else(|| "ICA 行动门：请先用 ica_propose_action 登记相同工具和参数、预期可观察结果，再执行。动作未执行。".into())
    }

    fn task_start_event(&self) -> usize {
        self.events
            .iter()
            .rposition(|e| e.source_type == "user")
            .map(|i| i + 1)
            .unwrap_or(0)
    }

    pub fn action_result(&mut self, future_id: &str, event_id: &str) {
        if let Some(f) = self.futures.iter_mut().find(|f| f.id == future_id) {
            f.result_event_id = event_id.into();
            f.state = "awaiting_comparison".into();
        }
    }

    pub fn observe(&mut self, source_type: &str, origin_id: &str, content: &str) -> String {
        let id = format!("E{}", self.events.len() + 1);
        self.events.push(Event {
            id: id.clone(),
            source_type: source_type.into(),
            origin_id: origin_id.into(),
            content: limit_content(content),
            retracted: false,
        });
        id
    }

    fn event(&self, id: &str) -> Option<&Event> {
        self.events.iter().find(|e| e.id == id)
    }

    fn claim_exists(&self, id: &str) -> bool {
        self.claims.iter().any(|c| c.id == id)
    }

    fn reassess_claim(&mut self, id: &str) {
        let mut positive = HashSet::new();
        let mut negative = HashSet::new();
        for r in self
            .evidence
            .iter()
            .filter(|r| r.active && r.claim_id == id)
        {
            if let Some(e) = self.event(&r.event_id) {
                if e.retracted || e.source_type == "user" || e.source_type == "tool_error" {
                    continue;
                }
                if r.supports {
                    positive.insert(e.origin_id.clone());
                } else {
                    negative.insert(e.origin_id.clone());
                }
            }
        }
        if let Some(c) = self.claims.iter_mut().find(|c| c.id == id) {
            c.state = if !negative.is_empty() {
                "contested"
            } else if positive.len() >= 2 {
                "needs_review"
            } else if positive.len() == 1 {
                "partial"
            } else {
                "locked"
            }
            .into();
        }
    }

    fn reassess_future(&mut self, id: &str) {
        let found = self
            .comparisons
            .iter()
            .filter(|x| x.active && x.future_id == id);
        let (mut yes, mut no) = (false, false);
        for x in found {
            if x.possible_match {
                yes = true
            } else {
                no = true
            }
        }
        if let Some(f) = self.futures.iter_mut().find(|f| f.id == id) {
            f.state = match (yes, no) {
                (true, true) => "contested",
                (true, false) => "possible_match",
                (false, true) => "possible_mismatch",
                (false, false) => "proposed",
            }
            .into();
        }
    }

    fn mark_dependents_stale(&mut self, upstream: &str, seen: &mut HashSet<String>) {
        if !seen.insert(upstream.to_string()) {
            return;
        }
        let downstream: Vec<String> = self
            .dependencies
            .iter()
            .filter(|(u, _)| u == upstream)
            .map(|(_, d)| d.clone())
            .collect();
        for id in downstream {
            if let Some(c) = self.claims.iter_mut().find(|c| c.id == id) {
                c.state = "stale".into();
            }
            self.mark_dependents_stale(&id, seen);
        }
    }

    pub fn summary(&self) -> String {
        let mut s = format!(
            "ICA: {} observations, {} claims, {} future items.",
            self.events.len(),
            self.claims.len(),
            self.futures.len()
        );
        for c in self.claims.iter().rev().take(6).rev() {
            s.push_str(&format!(
                "\n{} [{}] {}",
                c.id,
                c.state,
                limit_content(&c.text)
            ));
        }
        for f in self.futures.iter().rev().take(4).rev() {
            s.push_str(&format!(
                "\n{} [{}/{}] {}",
                f.id,
                f.kind,
                f.state,
                limit_content(&f.text)
            ));
        }
        for e in self.events.iter().rev().take(6).rev() {
            s.push_str(&format!(
                "\n{} [{}/{}]{}",
                e.id,
                e.source_type,
                e.origin_id,
                if e.retracted { " retracted" } else { "" }
            ));
        }
        s
    }

    pub fn final_note(&self) -> String {
        let current: Vec<&FutureItem> = self
            .futures
            .iter()
            .filter(|f| f.task_id == self.current_task)
            .collect();
        if !current.is_empty() {
            let states = current
                .iter()
                .map(|f| format!("{}:{}", f.id, f.state))
                .collect::<Vec<_>>()
                .join(", ");
            if current.iter().any(|f| !f.result_event_id.is_empty()) {
                return format!("[ICA 校准] {states}。只记录了动作回执；未由独立传感器确认目标状态，不能保证动作正确。此任务不会连续派发第二个动作。");
            }
            return format!("[ICA] 本任务候选状态 {states}。预测仍待现实结果检验。");
        }
        if self.claims.is_empty() {
            "[ICA 证据账本原型] 本轮没有登记可核验主张；此功能不是原生 ICA 时间想象模型，也未验证这段回答。".into()
        } else {
            format!(
                "[ICA 证据账本原型] 主张状态仍需人工核验；{} 个主张，{} 个待审。此功能不是原生 ICA 时间想象模型。",
                self.claims.len(),
                self.claims
                    .iter()
                    .filter(|c| c.state == "needs_review")
                    .count()
            )
        }
    }

    /// 八个 ICA 工具的统一入口；各分支的参数校验与入账在下方私有方法
    /// （2026-09-29 B1 拆分，行为逐字保持）。
    pub fn execute(&mut self, name: &str, args: &Value) -> Result<String, String> {
        match name {
            "ica_propose_claim" => self.propose_claim(args),
            "ica_propose_future" => self.propose_future(args),
            "ica_propose_action" => self.propose_action(args),
            "ica_cite_observation" => self.cite_observation(args),
            "ica_compare_future" => self.compare_future(args),
            "ica_depend" => self.depend(args),
            "ica_retract_observation" => self.retract_observation(args),
            "ica_status" => Ok(self.summary()),
            _ => Err(format!("未知 ICA 工具: {name}")),
        }
    }

    fn propose_claim(&mut self, args: &Value) -> Result<String, String> {
        let text = required(args, "text")?.to_string();
        let scope = args
            .get("scope")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        let id = format!("C{}", self.claims.len() + 1);
        self.claims.push(Claim {
            id: id.clone(),
            text,
            scope,
            state: "locked".into(),
        });
        Ok(format!("已登记 {id}，状态 locked；尚未核验。"))
    }

    fn propose_future(&mut self, args: &Value) -> Result<String, String> {
        let kind = required(args, "kind")?;
        if !["hypothesis", "plan", "unknown_gap", "action_proposal"].contains(&kind) {
            return Err("ICA future kind 无效".into());
        }
        let text = required(args, "text")?.to_string();
        let predicted_observation = args
            .get("predicted_observation")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        let id = format!("F{}", self.futures.len() + 1);
        self.futures.push(FutureItem {
            id: id.clone(),
            kind: kind.into(),
            text,
            predicted_observation,
            state: "proposed".into(),
            task_id: self.current_task,
            created_after_event: self.events.len(),
            tool: String::new(),
            arguments: Value::Null,
            result_event_id: String::new(),
        });
        Ok(format!("已登记未来候选 {id}；没有执行动作。"))
    }

    fn propose_action(&mut self, args: &Value) -> Result<String, String> {
        if !self.has_current_inspection() {
            return Err("ICA 请先读取本任务的机器人状态，再提出动作预测".into());
        }
        let tool = required(args, "tool")?.to_string();
        if !Self::action_tool(&tool) {
            return Err("ICA 仅接受 run_action_script、apply_sql、run_command 行动工具".into());
        }
        let arguments = args
            .get("arguments")
            .filter(|v| v.is_object())
            .ok_or("ICA 缺少对象字段 arguments")?
            .clone();
        let predicted_observation = required(args, "predicted_observation")?.to_string();
        let text = required(args, "reason")?.to_string();
        let id = format!("F{}", self.futures.len() + 1);
        self.futures.push(FutureItem {
            id: id.clone(),
            kind: "action_proposal".into(),
            text,
            predicted_observation,
            state: "proposed".into(),
            task_id: self.current_task,
            created_after_event: self.events.len(),
            tool,
            arguments,
            result_event_id: String::new(),
        });
        Ok(format!(
            "已登记行动候选 {id}。这不是执行结果；下一步须调用对应工具，随后比较现实回执。"
        ))
    }

    fn cite_observation(&mut self, args: &Value) -> Result<String, String> {
        let claim_id = required(args, "claim_id")?.to_string();
        let event_id = required(args, "event_id")?.to_string();
        if !self.claim_exists(&claim_id) || self.event(&event_id).is_none_or(|e| e.retracted) {
            return Err("ICA 引用的主张或观察不存在，或观察已撤回".into());
        }
        let supports = args
            .get("supports")
            .and_then(Value::as_bool)
            .unwrap_or(true);
        let id = format!("R{}", self.evidence.len() + 1);
        self.evidence.push(Evidence {
            id: id.clone(),
            claim_id: claim_id.clone(),
            event_id,
            supports,
            active: true,
        });
        self.reassess_claim(&claim_id);
        Ok(format!("已关联 {id}。{}", self.summary()))
    }

    /// ica_compare_future 的四重拒绝判据（B1 拆出）：候选不存在 / 观察不
    /// 存在或已撤回 / 观察早于候选登记（旧观察不能充当预测命中）/ 行动
    /// 候选只能与自己的执行回执比较。
    fn comparison_invalid(&self, future_id: &str, event_id: &str) -> bool {
        let Some(f) = self.futures.iter().find(|f| f.id == future_id) else {
            return true;
        };
        if self.event(event_id).is_none_or(|e| e.retracted) {
            return true;
        }
        if self
            .events
            .iter()
            .position(|e| e.id == event_id)
            .unwrap_or(0)
            < f.created_after_event
        {
            return true;
        }
        f.kind == "action_proposal" && f.result_event_id != event_id
    }

    fn compare_future(&mut self, args: &Value) -> Result<String, String> {
        let future_id = required(args, "future_id")?.to_string();
        let event_id = required(args, "event_id")?.to_string();
        let possible_match = args
            .get("possible_match")
            .and_then(Value::as_bool)
            .ok_or("ICA 缺少布尔字段 possible_match")?;
        if self.comparison_invalid(&future_id, &event_id) {
            return Err("ICA 对比的未来候选或后续观察不存在，或观察已失效".into());
        }
        let id = format!("X{}", self.comparisons.len() + 1);
        self.comparisons.push(Comparison {
            id: id.clone(),
            future_id: future_id.clone(),
            event_id,
            possible_match,
            active: true,
        });
        self.reassess_future(&future_id);
        Ok(format!("已登记暂定比较 {id}。{}", self.summary()))
    }

    fn depend(&mut self, args: &Value) -> Result<String, String> {
        let upstream = required(args, "upstream_id")?.to_string();
        let downstream = required(args, "downstream_id")?.to_string();
        if upstream == downstream
            || !self.claim_exists(&upstream)
            || !self.claim_exists(&downstream)
        {
            return Err("ICA 依赖关系无效".into());
        }
        self.dependencies.push((upstream, downstream));
        Ok("ICA 依赖关系已登记。".into())
    }

    fn retract_observation(&mut self, args: &Value) -> Result<String, String> {
        let id = required(args, "event_id")?.to_string();
        let Some(e) = self.events.iter_mut().find(|e| e.id == id && !e.retracted) else {
            return Ok("观察不存在或已经撤回。".into());
        };
        e.retracted = true;
        let affected: HashSet<String> = self
            .evidence
            .iter_mut()
            .filter(|r| r.event_id == id && r.active)
            .map(|r| {
                r.active = false;
                r.claim_id.clone()
            })
            .collect();
        for claim in affected {
            self.reassess_claim(&claim);
            self.mark_dependents_stale(&claim, &mut HashSet::new());
        }
        let futures: HashSet<String> = self
            .comparisons
            .iter_mut()
            .filter(|x| x.event_id == id && x.active)
            .map(|x| {
                x.active = false;
                x.future_id.clone()
            })
            .collect();
        for future_id in futures {
            self.reassess_future(&future_id);
        }
        Ok(format!("观察已撤回。{}", self.summary()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::fs;

    #[test]
    fn copied_origin_and_user_statement_cannot_verify_claim() {
        let mut ledger = IcaLedger::default();
        let c = ledger
            .execute("ica_propose_claim", &json!({"text":"测试主张"}))
            .unwrap();
        assert!(c.contains("C1"));
        let user = ledger.observe("user", "user", "测试主张是真的");
        ledger
            .execute(
                "ica_cite_observation",
                &json!({"claim_id":"C1","event_id":user}),
            )
            .unwrap();
        assert_eq!(ledger.claims[0].state, "locked");
        for _ in 0..2 {
            let e = ledger.observe("tool", "same-tool", "重复来源");
            ledger
                .execute(
                    "ica_cite_observation",
                    &json!({"claim_id":"C1","event_id":e}),
                )
                .unwrap();
        }
        assert_eq!(ledger.claims[0].state, "partial");
        let e = ledger.observe("tool", "other-tool", "第二来源");
        ledger
            .execute(
                "ica_cite_observation",
                &json!({"claim_id":"C1","event_id":e}),
            )
            .unwrap();
        assert_eq!(ledger.claims[0].state, "needs_review");
    }

    #[test]
    fn retraction_stales_dependents_and_undoes_future_comparison() {
        let mut ledger = IcaLedger::default();
        ledger
            .execute("ica_propose_claim", &json!({"text":"上游"}))
            .unwrap();
        ledger
            .execute("ica_propose_claim", &json!({"text":"下游"}))
            .unwrap();
        ledger
            .execute(
                "ica_depend",
                &json!({"upstream_id":"C1","downstream_id":"C2"}),
            )
            .unwrap();
        ledger
            .execute(
                "ica_propose_future",
                &json!({"kind":"hypothesis","text":"未来"}),
            )
            .unwrap();
        let e = ledger.observe("tool", "sensor", "观察");
        ledger
            .execute(
                "ica_cite_observation",
                &json!({"claim_id":"C1","event_id":e}),
            )
            .unwrap();
        ledger
            .execute(
                "ica_compare_future",
                &json!({"future_id":"F1","event_id":e,"possible_match":true}),
            )
            .unwrap();
        ledger
            .execute("ica_retract_observation", &json!({"event_id":e}))
            .unwrap();
        assert_eq!(ledger.claims[0].state, "locked");
        assert_eq!(ledger.claims[1].state, "stale");
        assert_eq!(ledger.futures[0].state, "proposed");
    }

    #[test]
    fn sidecar_requires_the_matching_session_file() {
        let path = std::env::temp_dir().join(format!("bot4cj-ica-test-{}", std::process::id()));
        fs::write(&path, b"session").unwrap();
        let name = path.to_str().unwrap();
        let mut ledger = IcaLedger::default();
        ledger.observe("user", "user", "hello");
        ledger.save(name).unwrap();
        assert_eq!(IcaLedger::load(name).unwrap().events.len(), 1);
        fs::write(&path, b"session changed").unwrap();
        assert!(IcaLedger::load(name).is_err());
        fs::remove_file(&path).unwrap();
        fs::remove_file(format!("{name}.ica.json")).unwrap();
    }

    #[test]
    fn action_requires_current_inspection_and_matching_prediction() {
        let mut ledger = IcaLedger::default();
        let args = json!({"name":"relay-test"});
        ledger.begin_task("运行脚本");
        assert!(ledger.authorize_action("run_action_script", &args).is_err());
        assert!(ledger
            .execute(
                "ica_propose_action",
                &json!({
                    "tool":"run_action_script", "arguments":args,
                    "reason":"测试继电器", "predicted_observation":"脚本成功"
                })
            )
            .is_err());
        ledger.observe("tool", "list_hardware", "继电器在位");
        assert!(ledger.authorize_action("run_action_script", &args).is_err());
        ledger
            .execute(
                "ica_propose_action",
                &json!({
                    "tool":"run_action_script", "arguments":args,
                    "reason":"测试继电器", "predicted_observation":"动作回执表明成功"
                }),
            )
            .unwrap();
        assert_eq!(
            ledger.authorize_action("run_action_script", &args).unwrap(),
            "F1"
        );
        assert!(ledger
            .authorize_action("run_action_script", &json!({"name":"other"}))
            .is_err());
        let result = ledger.observe("tool", "run_action_script", "脚本成功");
        ledger.action_result("F1", &result);
        assert!(ledger.authorize_action("run_action_script", &args).is_err());
        let unrelated = ledger.observe("tool", "list_hardware", "另一次状态");
        assert!(ledger
            .execute(
                "ica_compare_future",
                &json!({"future_id":"F1", "event_id":unrelated, "possible_match":true})
            )
            .is_err());
        ledger
            .execute(
                "ica_compare_future",
                &json!({
                    "future_id":"F1", "event_id":result, "possible_match":true
                }),
            )
            .unwrap();
        assert_eq!(ledger.futures[0].state, "possible_match");
        ledger
            .execute(
                "ica_propose_action",
                &json!({
                    "tool":"run_action_script", "arguments":args,
                    "reason":"再运行一次", "predicted_observation":"再次成功"
                }),
            )
            .unwrap();
        assert!(ledger.authorize_action("run_action_script", &args).is_err());
        ledger.begin_task("再运行一次");
        assert!(ledger.authorize_action("run_action_script", &args).is_err());
    }

    #[test]
    fn future_cannot_compare_with_earlier_observation() {
        let mut ledger = IcaLedger::default();
        ledger.begin_task("检查");
        let earlier = ledger.observe("tool", "list_hardware", "旧状态");
        ledger
            .execute(
                "ica_propose_future",
                &json!({
                    "kind":"hypothesis", "text":"稍后继电器会打开"
                }),
            )
            .unwrap();
        assert!(ledger
            .execute(
                "ica_compare_future",
                &json!({
                    "future_id":"F1", "event_id":earlier, "possible_match":true
                })
            )
            .is_err());
        let later = ledger.observe("tool", "read_variables", "新状态");
        assert!(ledger
            .execute(
                "ica_compare_future",
                &json!({
                    "future_id":"F1", "event_id":later, "possible_match":true
                })
            )
            .is_ok());
    }
}
