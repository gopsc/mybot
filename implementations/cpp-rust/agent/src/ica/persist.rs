//! ICA 账本的 sidecar 持久化（2026-09-29 B1 拆自 ica.rs）。
//!
//! 契约：`<会话文件>.ica.json`，权限 0600，临时文件 + fsync + rename 原子写；
//! 恢复要求 sidecar 记录的会话文件长度与当前文件一致（会话变了账本就不该
//! 被复用）。语义与拆分前逐字保持。

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;

use serde::{Deserialize, Serialize};

use super::IcaLedger;

#[derive(Serialize, Deserialize)]
struct SavedLedger {
    version: u32,
    session_size: u64,
    ledger: IcaLedger,
}

impl IcaLedger {
    pub fn save(&self, session_file: &str) -> Result<(), String> {
        if session_file.is_empty() {
            return Ok(());
        }
        let session_size = fs::metadata(session_file).map_err(|e| e.to_string())?.len();
        let sidecar = format!("{session_file}.ica.json");
        let temp = format!("{sidecar}.{}.tmp", std::process::id());
        let bytes = serde_json::to_vec(&SavedLedger {
            version: 1,
            session_size,
            ledger: self.clone_for_save(),
        })
        .map_err(|e| e.to_string())?;
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&temp)
            .map_err(|e| e.to_string())?;
        file.write_all(&bytes).map_err(|e| e.to_string())?;
        file.sync_all().map_err(|e| e.to_string())?;
        fs::rename(&temp, &sidecar).map_err(|e| e.to_string())
    }

    fn clone_for_save(&self) -> Self {
        Self {
            current_task: self.current_task,
            events: self.events.clone(),
            claims: self.claims.clone(),
            evidence: self.evidence.clone(),
            futures: self.futures.clone(),
            comparisons: self.comparisons.clone(),
            dependencies: self.dependencies.clone(),
        }
    }

    pub fn load(session_file: &str) -> Result<Self, String> {
        let sidecar = format!("{session_file}.ica.json");
        // 读前设限（2026-10-01 批次 A / P1-2）：误指向大文件时不整份进内存
        // （与会话文件/配置/提示词的处处设限同纪律，上限同 `BUDGET_BYTES_MAX`）。
        let cap = crate::config::limits::BUDGET_BYTES_MAX as u64;
        let len = fs::metadata(&sidecar)
            .map_err(|e| format!("ICA 账本读取失败 ({sidecar}): {e}"))?
            .len();
        if len > cap {
            return Err(format!(
                "ICA 账本 {sidecar} 大小 {len} 字节，超过上限 {cap} 字节——\
                 不像账本文件，拒绝读入"
            ));
        }
        let bytes = fs::read(&sidecar).map_err(|e| format!("ICA 账本读取失败 ({sidecar}): {e}"))?;
        let saved: SavedLedger =
            serde_json::from_slice(&bytes).map_err(|e| format!("ICA 账本解析失败: {e}"))?;
        let actual = fs::metadata(session_file).map_err(|e| e.to_string())?.len();
        if saved.version != 1 || saved.session_size != actual {
            return Err("ICA 账本与会话文件大小不一致，拒绝恢复".into());
        }
        Ok(saved.ledger)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// sidecar 落盘往返 + 会话长度一致性门（0600 权限）。
    /// IcaLedger 的行为面在 mod.rs 有 5 个用例；这里只钉持久化契约本身。
    #[test]
    fn save_then_load_roundtrips_and_rejects_drifted_session() {
        let dir = std::env::temp_dir().join(format!("mybot_ica_persist_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let session = dir.join("s.jsonl");
        std::fs::write(&session, "hello\n").unwrap();

        // 空路径是合法 no-op（未指定会话文件时不落盘）
        assert!(IcaLedger::default().save("").is_ok());

        let mut ledger = IcaLedger::default();
        ledger.begin_task("观察 LED 状态");
        ledger.save(session.to_str().unwrap()).unwrap();

        let sidecar = format!("{}.ica.json", session.to_str().unwrap());
        // 权限 0600：账本里可能有观察细节，不放宽给同组其它用户
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&sidecar).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, 0o600, "sidecar 权限应为 0600");
        }
        let back = IcaLedger::load(session.to_str().unwrap()).unwrap();
        assert_eq!(back.current_task, ledger.current_task);

        // 会话文件变长后拒绝恢复：会话已漂移，旧账本不该被复用
        std::fs::write(&session, "hello\nworld\n").unwrap();
        let err = match IcaLedger::load(session.to_str().unwrap()) {
            Ok(_) => panic!("会话漂移后应拒绝恢复"),
            Err(e) => e,
        };
        assert!(err.contains("大小不一致"), "{err}");

        // 会话文件缺失/路径为空：读取侧如实报错
        let missing = dir.join("none.jsonl");
        assert!(IcaLedger::load(missing.to_str().unwrap()).is_err());

        // 批次 A（P1-2）：超限 sidecar 在 read 之前拒绝（稀疏文件，不真写盘）
        let huge_session = dir.join("huge.jsonl");
        std::fs::write(&huge_session, "x\n").unwrap();
        let huge_sidecar = format!("{}.ica.json", huge_session.to_str().unwrap());
        let cap = crate::config::limits::BUDGET_BYTES_MAX as u64;
        let f = std::fs::File::create(&huge_sidecar).unwrap();
        f.set_len(cap + 1).unwrap();
        drop(f);
        let err = match IcaLedger::load(huge_session.to_str().unwrap()) {
            Ok(_) => panic!("超限 sidecar 必须被拒绝"),
            Err(e) => e,
        };
        assert!(err.contains("拒绝读入"), "实际: {err}");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
