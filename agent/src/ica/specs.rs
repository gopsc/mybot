//! 八个 ICA 本地工具的 schema 声明（2026-09-29 B1 拆自 ica.rs，逐字保持）。

use serde_json::{json, Value};

use crate::toolspec::ToolSpec;

pub fn specs() -> Vec<ToolSpec> {
    fn spec(name: &str, description: &str, schema: Value) -> ToolSpec {
        ToolSpec {
            name: name.into(),
            description: description.into(),
            parameters: schema,
        }
    }
    vec![
        spec(
            "ica_propose_claim",
            "记录待核验事实主张；不会自动验证。",
            json!({"type":"object","properties":{"text":{"type":"string"},"scope":{"type":"string"}},"required":["text"]}),
        ),
        spec(
            "ica_propose_future",
            "记录假设、计划、未知缺口或行动建议；不执行。",
            json!({"type":"object","properties":{"kind":{"type":"string","enum":["hypothesis","plan","unknown_gap","action_proposal"]},"text":{"type":"string"},"predicted_observation":{"type":"string"}},"required":["kind","text"]}),
        ),
        spec(
            "ica_propose_action",
            "在执行现实动作前，登记工具、完整参数、理由和预期可观察结果；登记不执行动作。",
            json!({"type":"object","properties":{"tool":{"type":"string","enum":["run_action_script","apply_sql","run_command"]},"arguments":{"type":"object"},"reason":{"type":"string"},"predicted_observation":{"type":"string"}},"required":["tool","arguments","reason","predicted_observation"]}),
        ),
        spec(
            "ica_compare_future",
            "把未来候选和之后的观察作暂定比较，不是事实验证。",
            json!({"type":"object","properties":{"future_id":{"type":"string"},"event_id":{"type":"string"},"possible_match":{"type":"boolean"}},"required":["future_id","event_id","possible_match"]}),
        ),
        spec(
            "ica_cite_observation",
            "把已有观察关联到主张；同来源只计一次。",
            json!({"type":"object","properties":{"claim_id":{"type":"string"},"event_id":{"type":"string"},"supports":{"type":"boolean"}},"required":["claim_id","event_id"]}),
        ),
        spec(
            "ica_depend",
            "记录主张间的依赖。",
            json!({"type":"object","properties":{"upstream_id":{"type":"string"},"downstream_id":{"type":"string"}},"required":["upstream_id","downstream_id"]}),
        ),
        spec(
            "ica_retract_observation",
            "撤回观察并使相关证据失效。",
            json!({"type":"object","properties":{"event_id":{"type":"string"}},"required":["event_id"]}),
        ),
        spec(
            "ica_status",
            "读取观察、主张、未来候选及其状态。",
            json!({"type":"object","properties":{}}),
        ),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ica::IcaLedger;
    use std::collections::BTreeSet;

    /// 声明面自身的完整性：名字唯一、全部 `ica_` 前缀（`merge_specs` 靠这个前缀
    /// 与后端工具名分域）、每条 schema 都是 `type: object`、`required` 里的每一项
    /// 都在 `properties` 里声明过（否则模型被要求填一个 schema 没描述的字段）。
    #[test]
    fn specs_are_well_formed_and_uniquely_named() {
        let all = specs();
        assert_eq!(all.len(), 8, "ICA 工具数变了？改动请同步 docs/agent.md");
        let names: BTreeSet<&str> = all.iter().map(|s| s.name.as_str()).collect();
        assert_eq!(names.len(), all.len(), "工具名有重复");
        for s in &all {
            assert!(s.name.starts_with("ica_"), "{}: 前缀不是 ica_", s.name);
            assert!(!s.description.trim().is_empty(), "{}: 描述为空", s.name);
            let p = &s.parameters;
            assert_eq!(
                p.get("type").and_then(Value::as_str),
                Some("object"),
                "{}: schema 顶层不是 object",
                s.name
            );
            let props = p.get("properties").and_then(Value::as_object);
            assert!(props.is_some(), "{}: 缺 properties", s.name);
            if let Some(req) = p.get("required").and_then(Value::as_array) {
                for r in req {
                    let key = r.as_str().unwrap_or_default();
                    assert!(
                        props.unwrap().contains_key(key),
                        "{}: required 里的 {key} 没有在 properties 里声明",
                        s.name
                    );
                }
            }
        }
    }

    /// **规格面 → 派发面的跨文件一致性守门**：`specs()` 声明的每个名字都必须被
    /// `IcaLedger::execute` 认得。否则模型拿到一条工具描述、照着调用，只会吃
    /// 「未知 ICA 工具」——这是本模块与 `ica/mod.rs` 分家（2026-09-29 B1）之后
    /// 最容易悄悄裂开的一条缝。
    ///
    /// 反向（有派发分支、无规格声明）不会让模型出错，只是死代码：由上面的
    /// `all.len() == 8` 与评审兜住，不在这里读源码扫描。
    ///
    /// 反向验证（2026-10-04）：把 `ica/mod.rs` 的 `"ica_depend"` 分支臂删掉后
    /// 本用例转红（报「未知 ICA 工具: ica_depend」），还原复绿。
    #[test]
    fn every_declared_spec_name_is_dispatchable() {
        let mut ledger = IcaLedger::default();
        for s in specs() {
            // 用空参数调用：多数分支会因缺必填字段而 Err，那是**参数校验**的错误，
            // 与「名字没人认」是两回事——只盯后者。
            if let Err(e) = ledger.execute(&s.name, &json!({})) {
                assert!(
                    !e.contains("未知 ICA 工具"),
                    "规格声明了 {} 但 execute 没有对应分支: {e}",
                    s.name
                );
            }
        }
    }

    /// 派发面对未声明的名字必须**明确拒绝**（回落分支存在且报错点名），
    /// 免得一个拼错的工具名被静默当成 no-op。
    #[test]
    fn execute_rejects_an_undeclared_tool_name() {
        let mut ledger = IcaLedger::default();
        let err = ledger.execute("ica_nonexistent", &json!({})).unwrap_err();
        assert!(err.contains("未知 ICA 工具: ica_nonexistent"), "{err}");
    }
}
