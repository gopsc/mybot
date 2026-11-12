//! C++ backend ↔ Rust agent framed-JSON protocol constants and payload types.
//!
//! Keep wire spelling here; transport framing remains in `frame.rs`.
use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const ROUTE_FIELD: &str = "_route";
pub const ROUTE_TOOL_LIST: &str = "tool.list";
pub const ROUTE_TOOL_CALL: &str = "tool.call";
pub const ROUTE_CONTEXT_GET: &str = "context.get";
pub const ROUTE_AUTH: &str = "auth";
pub const TOKEN_FIELD: &str = "token";
/* `tool.call` 请求体的两个键（bridge.rs 的调用构造点）。 */
pub const NAME_FIELD: &str = "name";
pub const ARGUMENTS_FIELD: &str = "arguments";
pub const REQUEST_ID_FIELD: &str = "requestId";
/* 信封字段的**手读**入口（frame.rs 的 authenticate、bridge.rs 的 resp_ok/resp_error）；
 * 结构化路径走下面的 `Response<T>` serde，不经这两个常量。C++ 侧同名常量在
 * src/mcp_protocol.hpp，两边由 test/cpp/test_mcptransport.cpp 的孪生用例互钉。 */
pub const SUCCESS_FIELD: &str = "success";
pub const ERROR_FIELD: &str = "error";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Response<T> {
    pub success: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<T>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolDescriptor {
    pub name: String,
    pub description: String,
    #[serde(rename = "inputSchema")]
    pub input_schema: Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolList {
    pub tools: Vec<ToolDescriptor>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ToolCallResult {
    pub text: String,
    #[serde(rename = "imageDataUrl", default)]
    pub image_data_url: String,
    #[serde(default)]
    pub ok: bool,
    #[serde(default)]
    pub error: String,
    #[serde(default)]
    pub executed: bool,
    #[serde(rename = "paramError", default)]
    pub param_error: bool,
    #[serde(default)]
    pub summary: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Context {
    #[serde(rename = "robotName")]
    pub robot_name: String,
    #[serde(rename = "structurePath")]
    pub structure_path: String,
    #[serde(rename = "scriptsDir")]
    pub scripts_dir: String,
    #[serde(rename = "allowShell")]
    pub allow_shell: bool,
    #[serde(rename = "allowHotSql")]
    pub allow_hot_sql: bool,
    #[serde(rename = "hardwareCount")]
    pub hardware_count: u64,
    #[serde(rename = "structureExcerpt")]
    pub structure_excerpt: String,
    #[serde(rename = "hardwareList")]
    pub hardware_list: String,
    #[serde(rename = "scriptsList")]
    pub scripts_list: String,
    #[serde(rename = "readableVars")]
    pub readable_vars: String,
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn request_id_wire_name_is_stable() {
        assert_eq!(REQUEST_ID_FIELD, "requestId");
    }

    #[test]
    fn tool_result_uses_wire_field_names_and_roundtrips() {
        let result = ToolCallResult {
            text: "done".into(),
            image_data_url: "data:image/png;base64,aGk=".into(),
            ok: false,
            error: "failed".into(),
            executed: true,
            param_error: false,
            summary: "one change".into(),
        };
        let value = serde_json::to_value(&result).unwrap();
        assert_eq!(
            value,
            json!({
                "text":"done", "imageDataUrl":"data:image/png;base64,aGk=", "ok":false,
                "error":"failed", "executed":true, "paramError":false, "summary":"one change"
            })
        );
        let decoded: ToolCallResult = serde_json::from_value(value).unwrap();
        assert_eq!(decoded.text, "done");
        assert_eq!(decoded.image_data_url, result.image_data_url);
        assert_eq!(decoded.param_error, result.param_error);
    }
}
