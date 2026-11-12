//! budget.rs —— 任务内聚合预算（`src/agentbudget.cpp` / `agentbudget.hpp` 的镜像）
//!
//! max_turns 只管「模型回合数」，历史裁剪（history::trim）只管「已完结的旧任务块」
//! 且最新块无条件保留——于是**正在进行的任务**原本没有任何体积上限：模型多调
//! 几次工具就能在一个任务里把请求体顶穿网关限额，而那块历史既不在回滚范围内、
//! 也不能被裁掉，REPL 从此每条任务都以同一个请求体失败。
//!
//! TaskBudget 约束「单个任务往上下文里灌了多少字节」：
//!   * 文本与图片（data URL）两条额度逐次累加，超限时**不把该次结果放进上下文**，
//!     原地替换为一句降级说明（admit 返回 true）；
//!   * 为什么是「换掉」而不是「截断」：截断工具输出会让模型看到半截内容却以为
//!     完整（比没有更危险）；为什么不是「报错终止」：那是把可用性问题升级成任务
//!     失败，而模型完全有能力换一个小一点的步子重试；
//!   * 判定在**执行之后**做：体积要拿到结果才知道，而工具已经产生副作用（比如
//!     动作脚本已经跑了），此时谎称「没执行」会误导模型——降级说明必须如实写明
//!     「已执行，但结果体积超限」（项目口径：不向模型谎报状态）。
//!
//! 除体积外还管**时间**：agent 模式全程机器带电常驻，而 max_turns × 单次调用
//! 超时 × 单轮调用数三个因子相乘没有一处封顶。max_seconds 给单个任务的墙钟封顶
//! （0 = 不限，逃生口），exhausted() 供编排层在「轮循环开头」与「逐条派发之前」
//! 两处判定——两处都要判，语义不同（见 hook.rs）。
//!
//! 每轮任务开始时由调用方 reset_task() 清零（体积与墙钟起点一起）；跨任务的体积
//! 由 history::trim 管。

use std::time::{Duration, Instant};

pub struct TaskBudget {
    /// 0 = 不限
    pub max_tool_result_bytes: usize,
    /// 0 = 不限
    pub max_image_bytes: usize,
    /// 单任务墙钟预算；0 = 不限
    pub max_seconds: i64,
    /// 当前任务已注入的文本字节
    pub tool_result_bytes: usize,
    /// 当前任务已注入的图片字节
    pub image_bytes: usize,
    /// 当前任务的墙钟起点。用单调时钟：系统时间被 NTP 拨动不该影响一个正在跑的
    /// 动作任务。
    pub task_start: Instant,
}

impl TaskBudget {
    pub fn new(max_tool_result_bytes: usize, max_image_bytes: usize, max_seconds: i64) -> Self {
        Self {
            max_tool_result_bytes,
            max_image_bytes,
            max_seconds,
            tool_result_bytes: 0,
            image_bytes: 0,
            task_start: Instant::now(),
        }
    }

    pub fn reset_task(&mut self) {
        self.tool_result_bytes = 0;
        self.image_bytes = 0;
        self.task_start = Instant::now();
    }

    /// 单任务墙钟预算是否已耗尽。max_seconds <= 0 时恒为 false。
    pub fn exhausted(&self) -> bool {
        if self.max_seconds <= 0 {
            return false;
        }
        self.task_start.elapsed() >= Duration::from_secs(self.max_seconds as u64)
    }

    /// 预算判定与记账（原地改写）。超限时把 `*text` 替换为降级说明、`*image`
    /// 清空并返回 true；否则把两者计入额度并返回 false。
    ///
    /// `executed`（SAN-4）：这一次调用是否真的被派发给了工具。**false 时不做降级**
    /// ——那三种情形（策略拒绝 / 未知工具 / 参数错误）根本没执行，副作用必然未发生，
    /// 而无条件追加「工具本身已执行完毕（副作用已发生）」等于对模型谎报硬件状态。
    /// 这类文本本身也极短（≤200 字节），没有降级的必要：**它们必须原样到达模型**。
    /// 执行过但失败的调用（脚本跑到一半报错）仍然降级并保留原口径——那时的副作用
    /// 确实可能已发生。记账照做：额度是「往上下文里灌了多少字节」的账，与执不执行
    /// 无关；跳过记账会让「反复拒绝」变成灌历史的免费通道。
    pub fn admit(&mut self, text: &mut String, image: &mut String, executed: bool) -> bool {
        if !executed {
            self.tool_result_bytes += text.len();
            self.image_bytes += image.len();
            return false;
        }
        let text_over = self.max_tool_result_bytes > 0
            && self.tool_result_bytes + text.len() > self.max_tool_result_bytes;
        let img_over = !image.is_empty()
            && self.max_image_bytes > 0
            && self.image_bytes + image.len() > self.max_image_bytes;
        if text_over || img_over {
            let what = if img_over { "图片" } else { "工具输出" };
            let used = if img_over {
                self.image_bytes
            } else {
                self.tool_result_bytes
            };
            let cap = if img_over {
                self.max_image_bytes
            } else {
                self.max_tool_result_bytes
            };
            let size = if img_over { image.len() } else { text.len() };
            let mut note = format!(
                "本次工具结果未注入上下文：{what}累计体积已达任务上限（已用 {used} + 本次 \
                 {size} 字节，上限 {cap} 字节）。"
            );
            if img_over {
                // AG-4′：这里曾原样拼进 capture_image 的成功文案，而那句末尾是
                // 「画面已加入你的上下文」——与本条开头的「未注入上下文」直接矛盾，
                // 而**图片确实没注入**。既有的口径是「不向模型谎报状态」，所以把描述里
                // 那句成功断言剥掉，再显式说明「只把描述给你」。
                let mut desc = text.clone();
                const CLAIM: &str = "画面已加入你的上下文。";
                if let Some(at) = desc.find(CLAIM) {
                    desc.replace_range(at..at + CLAIM.len(), "");
                }
                note += "已把工具的描述性文字给你（画面本身没有进上下文）：";
                note += &desc;
                // 图片预算是**逐任务单向累加**的：一旦某张图装不下，本任务就再也塞不进
                // 任何图片（额度只增不减）。不明说的话，模型会一直重试拍照直到轮次上限。
                // 判据必须与上面触发降级的判据**逐字一致**（都是「已用 + 本次 > 上限」）：
                // 写成 used >= cap 是错的——本次 87 / 上限 100 / 已用 87 时 used < cap，
                // 但再拍一张必然还是 87+87 > 100，额度事实上已经用尽。
                if used + image.len() > cap {
                    note += "本任务的图片额度已经用尽，**再调用也不会成功**；\
                             请立即改用文字结论或换一个新任务。";
                }
            }
            note += "工具本身已执行完毕（副作用已发生）。请改用更小的步子推进任务，\
                     或直接基于已有信息给出结论。";
            // AG-21：降级说明**自己也计入预算**——否则「反复超限」可以往历史里无界灌
            // 说明文本（每条约 300 字节 x 轮数 x 每轮调用数）。计入之后第一次降级就把
            // 额度顶满，后续调用走同一分支且文案不变（幂等，不会雪崩）。
            self.tool_result_bytes += note.len();
            *text = note;
            image.clear();
            return true;
        }
        self.tool_result_bytes += text.len();
        self.image_bytes += image.len();
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn budget(text_cap: usize, img_cap: usize) -> TaskBudget {
        TaskBudget::new(text_cap, img_cap, 0)
    }

    /// SAN-4：没执行的调用（策略拒绝/未知工具/参数错误）不降级，原文逐字保留；
    /// 但**照样记账**（否则「反复拒绝」成了灌历史的免费通道）。
    #[test]
    fn not_executed_is_never_downgraded_but_still_accounted() {
        let mut b = budget(1, 1); // 额度小到任何文本都会超
        let mut text = "策略拒绝：capture_image 不在允许清单里".to_string();
        let original = text.clone();
        let mut image = String::new();
        assert!(!b.admit(&mut text, &mut image, false), "未执行 → 不降级");
        assert_eq!(text, original, "未执行的文案必须原样到达模型");
        assert_eq!(b.tool_result_bytes, original.len(), "未执行也要记账");
        // 图片同理：未执行时即使超限也不替换（只记账）
        let mut t2 = String::new();
        let mut img = "data:image/png;base64,AAAA".to_string();
        assert!(!b.admit(&mut t2, &mut img, false));
        assert_eq!(img, "data:image/png;base64,AAAA");
        assert_eq!(b.image_bytes, 26);
    }

    /// 文本超限：原地换成降级说明，文案逐字同 C++（含「已执行」口径）。
    #[test]
    fn text_over_budget_replaces_with_note() {
        let mut b = budget(10, 0);
        let mut text = "0123456789A".to_string(); // 11 > 10
        let mut image = String::new();
        assert!(b.admit(&mut text, &mut image, true));
        assert!(
            text.starts_with("本次工具结果未注入上下文：工具输出累计体积已达任务上限（已用 0 + 本次 11 字节，上限 10 字节）。"),
            "实际: {text}"
        );
        assert!(text.ends_with(
            "工具本身已执行完毕（副作用已发生）。请改用更小的步子推进任务，或直接基于已有信息给出结论。"
        ));
        assert!(!text.contains("图片额度"), "文本降级不提图片额度: {text}");
        // AG-21：降级说明自己也计入预算
        assert_eq!(b.tool_result_bytes, text.len());
    }

    /// 图片超限且额度用尽：明确告知终态，并剥掉工具成功文案里的「画面已加入你的上下文」。
    #[test]
    fn image_exhaustion_is_terminal_and_stated() {
        let mut b = budget(0, 100);
        // 第一张 87 字节：0 + 87 <= 100，装得下
        let mut text = "拍照完成。画面已加入你的上下文。".to_string();
        let mut img = "x".repeat(87);
        assert!(!b.admit(&mut text, &mut img, true));
        assert_eq!(img.len(), 87);
        assert_eq!(b.image_bytes, 87);
        // 第二张 87 字节：87 + 87 > 100 → 降级；used(87) + 87 > cap(100) → 额度耗尽终态
        let mut text2 = "拍照完成。画面已加入你的上下文。".to_string();
        let mut img2 = "y".repeat(87);
        assert!(b.admit(&mut text2, &mut img2, true));
        assert!(img2.is_empty(), "降级时图片必须清空");
        assert!(
            text2.contains(
                "本次工具结果未注入上下文：图片累计体积已达任务上限（已用 87 + 本次 87 字节，上限 100 字节）。"
            ),
            "实际: {text2}"
        );
        assert!(
            text2.contains("已把工具的描述性文字给你（画面本身没有进上下文）：拍照完成。"),
            "成功断言必须被剥掉、只留描述: {text2}"
        );
        assert!(
            !text2.contains("画面已加入你的上下文"),
            "不得留矛盾断言: {text2}"
        );
        assert!(
            text2.contains("本任务的图片额度已经用尽，**再调用也不会成功**；请立即改用文字结论或换一个新任务。"),
            "实际: {text2}"
        );
    }

    /// 0 = 不限：任何体积都不降级。
    #[test]
    fn zero_caps_mean_unlimited() {
        let mut b = budget(0, 0);
        let mut text = "x".repeat(1 << 20);
        let mut image = "data:image/png;base64,".to_string() + &"A".repeat(1 << 20);
        assert!(!b.admit(&mut text, &mut image, true));
        assert_eq!(text.len(), 1 << 20);
        assert!(!image.is_empty());
    }

    #[test]
    fn wall_clock_budget_and_reset() {
        let mut b = TaskBudget::new(0, 0, 0);
        assert!(!b.exhausted(), "0 = 不限");
        b.max_seconds = 3600;
        assert!(!b.exhausted());
        b.task_start -= Duration::from_secs(3601);
        assert!(b.exhausted());
        b.reset_task();
        assert!(!b.exhausted(), "reset_task 同时重置墙钟起点");
        assert_eq!(b.tool_result_bytes, 0);
        assert_eq!(b.image_bytes, 0);
    }
}
