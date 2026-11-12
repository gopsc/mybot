//! 工具描述的载体类型（后端 `tool.list` 的一条）。
//!
//! 2026-10-01 自 bridge.rs 下沉为叶子模块（解 `bridge ↔ ica` 类型级环：ica/specs
//! 声明工具 schema 需要本类型，此前反向依赖传输层 bridge 的定义——与 placeholder.rs
//! 解 `session ↔ history` 环同一手法）。bridge 与 ica 均单向依赖本模块。

use serde_json::Value;

/// 一条工具描述（后端 `tool.list` 的一条）。
#[derive(Debug, Clone)]
pub struct ToolSpec {
    pub name: String,
    pub description: String,
    /// JSON Schema object（非对象时回落 `{"type":"object"}`，不让一个坏 schema
    /// 整条 list 失败）
    pub parameters: Value,
}
