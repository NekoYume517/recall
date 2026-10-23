# 项目计划书 — recall：MoonBit 的间隔重复调度引擎

> 仓库：<https://github.com/NekoYume517/recall>
> 赛事：MoonBit Hackathon 2026
> 状态：已交付（`moon check` 0 错误 · 378 测试全绿 · CI 全绿 · wasm 构建通过）

---

## 1. 背景与动机

间隔重复（spaced repetition）是记忆科学里证据最充分的应用之一：在遗忘临界点安排复习，用最少的时间维持长期记忆。Anki 的 2 亿下载量证明了需求，但其调度算法是黑盒，且无法嵌入其他产品。

MoonBit 生态没有任何调度算法库（mooncakes 检索 `fsrs / anki / leitner` 零命中）。同时这个领域有一个很适合展示语言能力的特性：**三代算法可以共用同一个接口**——SM-2（1987，SuperMemo 的经典）、FSRS-5（2023，基于遗忘曲线拟合的现代算法）、Leitner（1970，盒子基线）。一个 `Scheduler` trait、三份实现、同一份复习日志上重放对比，就是最直接的算法教学素材。

## 2. 目标

**做**：一个引擎，三件事——

1. **调度**：三种算法统一接口（评分 → 新状态），可插拔
2. **重放**：同一份 JSONL 复习日志在任何调度器上确定性重放，产出统计与保留率曲线
3. **对比与预测**：两调度器逐卡对比；按每日新增/复习上限模拟未来积压

**不做**：不做 GUI、不做同步服务、不做卡片内容管理——只做调度内核，让应用层自己长。

## 3. 技术方案

### 3.1 统一接口的代价与收益

`Scheduler` trait 的四个方法（name / init / review / is_recalled）让三种算法可互换。但三代算法的状态语义不同：FSRS 有 stability/difficulty，SM-2 只有 EF + interval，Leitner 只有盒号。方案是**一个 `CardState` 多路复用**（`difficulty` 按调度器分派：FSRS=D(1..10)、SM-2=EF、Leitner=盒号），契约写在类型注释里，CLI 显示列按调度器改名（难度/EF/盒号）。跨调度器比较 difficulty 没有意义——这句话也写进了 API。

### 3.2 FSRS 是精度标杆

FSRS-5 的三组更新公式（stability 增强/衰减、难度更新、间隔反解）逐项对照官方权重实现。两个定义性不变量作为测试锚点：`R(t=S, S)=0.9`、`interval_days(S, 0.9)=S`（后者的成立域是 S ∈ [1, 36500]，超出被 min/max 夹取）。难度更新曾经漏了 linear damping，导致 D 一次顶到 10 后失去分辨率——修复后 90 天模拟复习量降 14%。这类公式 bug 只有「手算表逐项比对」能抓，`sm2_test.mbt` 里四组手算表（含最容易算错的 `Again` 的 EF 增量 -0.32）就是这么来的。

### 3.3 模拟器必须耦合积压与遗忘

模拟器最容易被写错的地方：评分策略拿不到"现在是第几天"。旧实现用计划间隔当真实流逝时间，结果**积压越久记住率反而越高**——自我强化的遗忘回路完全失效。修复方式是把传入评分器的状态副本里的间隔换成真实 elapsed。这条耦合修好后，`--review-limit 50` 的 90 天积压从乐观的 760 变成真实的 1287。

### 3.4 Int64 时间戳的防御

时间运算用 Int64 秒级时间戳。双层防护：间隔天数封顶 100 年 + `add_days` 加法饱和（`now` 逼近上限时回绕会让卡片"永久到期"）。NaN 显式兜底。

## 4. 实施里程碑

| 阶段 | 内容 | 验收标准 |
|---|---|---|
| M1 类型与日志 | Grade/CardState/ReviewEvent，JSONL 无损序列化 | 往返无损；BOM/坏行/越界评分有明确错误 |
| M2 三调度器 | SM-2 手算表、Leitner 基线、FSRS 完整实现 | 手算表逐项一致；FSRS 不变量成立 |
| M3 引擎 | 确定性重放、对比、模拟、统计、曲线 | 同一输入两次运行输出逐字节相同 |
| M4 CLI 与预测 | replay/compare/simulate/stats/curve | 每条命令实测；模拟数字可复现 |

## 5. 质量保障

- **378 个测试**（含权重验证、负载建议、Anki 导出的专项测试），含对抗性审查的 24 个回归（JSONL 极端输入、权重越界、同日复习、提前复习、CLI fuzz）
- **样例数据本身被审计**：750 条事件的 `elapsed_days` 必须与时间戳差严格一致（生成脚本自检 0 mismatch），评分由遗忘曲线抽样决定——曾有版本两套逻辑各写各的，导致 replay 与 curve 互相矛盾
- **两轮审查**：子代理审计修复 2 个深层 bug（BOM 拒收整份日志、`add_days` 二层回绕）；外部复验确认 4 条修复、抓出 CLI 参数静默默认等尾巴并已修
- **诚实文档**：`--retention` 曾承诺了不存在的旋钮，修复后 CLI 对不支持该参数的算法明说"未生效（仅 FSRS 支持）"

## 6. 差异化

- **算法对比是一等公民**：`compare` 不只比间隔总和，还报告触顶卡数（SM-2 有 4/25 张卡顶到 100 年上限=永远不再复习）并主动警告"间隔长不等于好"
- **确定性可复现**：同 seed 同日志，两次模拟输出逐字节相同——DEMO 里每个数字都能重跑出来
- **MoonBit wasm**：调度内核可以内嵌到任何 wasm 宿主（浏览器插件、Edge 函数）

## 7. 后续路线

1. ~~FSRS 权重微调接口~~ ✅ 已完成：`validate_fsrs_weights` / `validate_fsrs_semantics` / `validate_fsrs_reference` 三层验证 + `Fsrs::with_params_checked` 严格构造器（2026-10-21）
2. 负载优化建议器（给定积压目标反推每日新增上限）
3. ~~导出 Anki 可读格式~~ ✅ 已完成：`export_anki_tsv` / `export_anki_from_log` + CLI `--anki`（2026-10-21）

## 8. 提交信息

- 仓库：<https://github.com/NekoYume517/recall>
- 许可：Apache-2.0
- 演示：`docs/DEMO.md` 十一步，从"积压预测"到"FSRS 不变量"，每个数字可复现
- 技术细节：`docs/implementation.md`（12 个技术判断 + 5 个真实 bug）与 `docs/grade-mapping.md`（两套整数的陷阱）
