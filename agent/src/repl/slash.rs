//! repl/slash.rs —— REPL 斜杠命令域（/help /clear /status /hardware /scripts /sql）
//!
//! 2026-10-01 自 repl.rs 拆出（行为保持）：命令分派、SQL 变更语句甄别
//! （`batch_has_write_ops`，Rust 唯一实现）与用法/帮助文案。作为 repl 的子模块，
//! 经 `super::Session` 调会话方法，不引入跨模块环。

use crate::out::outln;

use super::Session;

/// SQL 变更语句甄别（Rust 唯一实现）：「整批都是只读」才走 `query_sql`，
/// 混排批次里的写语句必须被看见（否则 `SELECT…; DELETE…` 会静默丢后半句）。
pub(super) fn batch_has_write_ops(sql: &str) -> bool {
    for stmt in sql.split(';') {
        let first = stmt.split_whitespace().next().unwrap_or("");
        if ["CREATE", "INSERT", "DELETE", "DROP", "UPDATE"]
            .iter()
            .any(|k| first.eq_ignore_ascii_case(k))
        {
            return true;
        }
    }
    false
}

/// `/sql` 的用法串（空语句时打印）。
const SQL_USAGE: &str = "用法: /sql <语句>（以 ; 结尾），例如 /sql SELECT * FROM Vars;\n\
     可加等值条件（AND 连接），例如 /sql SELECT * FROM Servo WHERE name = 's1';\n\
     SHOW TABLES 列出当前结构的全部表名与数据行数，例如 /sql SHOW TABLES;\n\
     DELETE 会当场断电摘除匹配行且不可逆，例如 /sql DELETE FROM Servo WHERE name = 's1';\n\
     UPDATE 按断电重建改写命中行（先断电摘除再重装），例如 /sql UPDATE Servo SET angle = 90 WHERE name = 's1';";

const HELP_TEXT: &str = "内置命令:\n\
  /hardware  - 显示硬件清单（只读，不触发任何动作）\n\
  /scripts   - 显示可用动作脚本清单（相对路径 + 首行注释）\n\
  /sql <语句> - 执行结构 SQL：SELECT * FROM t [WHERE 列 = 值 [AND ...]] / SHOW TABLES 只读查询运行时矩阵（SHOW TABLES 列出全部表名与数据行数）；\n\
               CREATE TABLE / INSERT INTO 立即带电生效（失败全回滚）；\n\
               DELETE FROM t [WHERE 列 = 值 [AND ...]] 当场断电摘除匹配行（不可逆）；\n\
               UPDATE t SET 列 = 值 [, ...] [WHERE ...] 按断电重建改写命中行（删旧件 + 装新件）\n\
  /status    - 会话状态一览（历史/预算/用量/审计落点，只读）\n\
  /clear     - 清空对话记忆（保留硬件上电状态与系统提示词）\n\
  /help      - 显示此帮助\n\
  /exit      - 退出 agent 模式\n\
  /quit      - 同 /exit\n\
直接输入任务描述即可让智能体执行，例如：\n\
  让机器人站立\n\
  拍照并描述看到的内容";

/// 「后端没开工具」的报错文案单点（/hardware 与 /scripts 共用；/sql 那份不并——
/// 它带 flag 与「配置文件不能放宽，只能收紧」子句，结构不同）。
fn missing_tool_error(tool: &str) -> String {
    format!("错误: 后端没有提供 {tool} 工具（检查 mybot --mcp-backend 那一侧的开关）")
}

/// 斜杠命令分派（B4 拆自 run_repl 循环体）：命中并处理完毕返回 true
/// （调用方 continue，不进模型）；不是斜杠命令返回 false（当任务发给模型）。
/// hw 是当轮提示符已取好的硬件数（/status 复用，避免二次往返）。
/// `/exit` 不在这里——它在历史 remember 之前就 break，时序与拆分前一致。
pub(super) async fn handle_slash_command(
    session: &mut Session,
    task: &str,
    hw: Option<u64>,
) -> bool {
    if task == "/help" {
        outln!("{HELP_TEXT}");
        return true;
    }
    if task == "/clear" {
        session.clear_history();
        outln!("已清空对话记忆（硬件保持上电，系统提示词不变）。");
        return true;
    }
    if task == "/status" {
        outln!("{}", session.status_text(hw));
        return true;
    }
    if task == "/hardware" {
        if !session.has_tool("list_hardware") {
            outln!("{}", missing_tool_error("list_hardware"));
            return true;
        }
        outln!(
            "{}",
            session
                .call_tool("list_hardware", serde_json::json!({}))
                .await
        );
        return true;
    }
    if task == "/scripts" {
        if !session.has_tool("list_action_scripts") {
            outln!("{}", missing_tool_error("list_action_scripts"));
            return true;
        }
        outln!(
            "{}",
            session
                .call_tool("list_action_scripts", serde_json::json!({}))
                .await
        );
        return true;
    }
    // /sql <语句>：全只读走 query_sql；含变更语句走 apply_sql（后端那侧才真正
    // 带电生效/断电摘除）。
    if task.starts_with("/sql")
        && matches!(
            task.as_bytes()[4..].first(),
            None | Some(b' ') | Some(b'\t')
        )
    {
        let sql = task[4..].trim();
        if sql.is_empty() {
            outln!("{SQL_USAGE}");
            return true;
        }
        let (tool, flag) = if batch_has_write_ops(sql) {
            ("apply_sql", "--agent-hot-sql")
        } else {
            ("query_sql", "--agent-hot-sql")
        };
        if !session.has_tool(tool) {
            outln!(
                "错误: 后端没有提供 {tool} 工具——结构 SQL 需要 mybot --mcp-backend 侧开 {flag}\
                 （配置文件不能放宽，只能收紧）"
            );
            return true;
        }
        outln!(
            "{}",
            session
                .call_tool(tool, serde_json::json!({ "sql": sql }))
                .await
        );
        return true;
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sql_batch_write_op_detection() {
        // 全只读 → query_sql 通道
        assert!(!batch_has_write_ops("SELECT * FROM Servo;"));
        assert!(!batch_has_write_ops(
            "  select * from Vars where name = 'a'; SHOW TABLES;"
        ));
        assert!(!batch_has_write_ops(""));
        // 大小写不敏感 + 混排批次里的写语句必须被看见
        assert!(batch_has_write_ops("create table X (a INT);"));
        assert!(batch_has_write_ops(
            "SELECT * FROM T; INSERT INTO T VALUES ('x');"
        ));
        for kw in [
            "DELETE FROM T;",
            "DROP TABLE T;",
            "UPDATE T SET a = 1;",
            "insert into t values (1);",
        ] {
            assert!(batch_has_write_ops(kw), "应判为变更语句: {kw}");
        }
        // 关键字只在行首算：列/值里出现 create 不算变更
        assert!(!batch_has_write_ops(
            "SELECT * FROM T WHERE note = 'create table';"
        ));
    }
}
