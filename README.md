# recall

**间隔重复调度引擎：SM-2 / FSRS / Leitner 的统一实现，加日志重放与积压预测。**

[![MoonBit](https://img.shields.io/badge/MoonBit-0.1.20261012-blueviolet)](https://www.moonbitlang.com/)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)

---

## 为什么

Anki 有数百万用户，"复习积压"是社区里最常被抱怨的问题。但整个调度逻辑分散在：

- Anki 的 Rust rslib 里，和 UI 强耦合
- FSRS 官方实现是 PyTorch（要训练）和 JS（只服务前端）
- 各种语言的重写版本质量参差，多数照抄公式不抄边界

而且**没有一个工具能回答**："如果我每天学 20 张新卡，三个月后会积压多少？"

`recall` 把调度算法从 UI 里剥出来，做成一个可替换、可重放、可模拟的引擎。

## 两种算法的差别

**SM-2**（1987，Anki 祖传）只有一个难度因子 EF：

```
答对: interval(n) = interval(n-1) × EF
答错: interval = 1
EF 下限 1.3
```

问题：**EF 是一维的**。"难但已背熟"和"简单但刚学"的卡片可能 EF 相同，但最优复习时间完全不同。

**FSRS**（2022+，Anki 23.10 起内置）用三个状态：

| 符号 | 含义 |
|---|---|
| **D** | Difficulty，这张卡本身多难（1–10） |
| **S** | Stability，记忆保持天数 |
| **R** | Retrievability，此刻还记得的概率 |

遗忘曲线：

```
R(t, S) = (1 + 19/81 × t/S)^(-0.5)
```

当 `t = S` 时 `R ≈ 0.9`。**S 的定义就是"回忆概率衰减到 90% 所需的天数"**——直接可解释。

FSRS 相对 SM-2 的差异在本仓库可以复现的部分见 `compare` 命令与
`docs/DEMO.md`：对同一份 25 卡日志，SM-2 有 4 张卡把间隔推到 100 年
上限（等价于不再复习），FSRS 是 0 张。「同等保持率下少 20–30% 复习量」
是 FSRS 论文的结论，本仓库未做受控实验来复核它。

## 快速开始

**作为库依赖**（已发布到 [mooncakes.io](https://mooncakes.io/docs/NekoYume517/recall)）：

```bash
moon add NekoYume517/recall
```

```moonbit
let s = @recall.Fsrs::new()
let c0 = @recall.CardState::new("c1", 0L)
let c1 = @recall.apply_review(s, c0, @recall.Good, 0L)  // 返回新的 CardState
```

**作为命令行工具**（源码运行）：

```bash
moon check
moon test

# 用示例日志对比两种调度器
moon run cmd/recall -- compare --log examples/reviews.jsonl --a sm2 --b fsrs

# 预测未来 90 天的复习量
moon run cmd/recall -- simulate --scheduler fsrs --days 90 --new-per-day 20 --review-limit 200

# 看自己的保留率曲线
moon run cmd/recall -- curve --log examples/reviews.jsonl --buckets 10
```

## 命令

```bash
recall replay   --log <file.jsonl> --scheduler sm2|fsrs|leitner [--json]
recall compare  --log <file.jsonl> --a sm2 --b fsrs
recall simulate --scheduler fsrs --days 90 --new-per-day 20 --review-limit 200 --policy realistic
recall stats    --log <file.jsonl>
recall curve    --log <file.jsonl> --buckets 10
```

## 复习日志格式

日志是**唯一真相来源**：所有状态由重放得到，不存冗余状态。每行一个事件：

```json
{"card_id":"c1","reviewed_at":1700000000,"due_at":1699999000,"grade":3,"elapsed_days":1.0}
```

| 字段 | 含义 |
|---|---|
| `card_id` | 卡片标识 |
| `reviewed_at` | 实际复习时刻（Unix 秒） |
| `due_at` | 当时系统认为的到期时刻（用于算 overdue） |
| `grade` | 0=Again 1-2=Hard 3=Good 4-5=Easy |
| `elapsed_days` | 距上次复习天数，首次为 0 |

## 设计要点

**日志优先。** 状态是可重放的推导结果，不是独立存储的事实。这让"换调度器重算历史"成为一次纯函数调用。

**确定性。** 模拟器的伪随机用固定种子的 LCG，不是系统随机。同一输入必须给同一输出——否则无法测试，也无法对比。

**调度器可替换。** 一切通过 `Scheduler` trait 调用。新算法接入不需要改重放器、模拟器、统计器。

**性质可测。** 调度器和统计器有明确的不变量：固定状态下 Good 的间隔 ≥ Hard；SM-2 的 EF 不低于 1.3；保持率落在 [0,1]；跨卡事件交错不改变间隔统计。经验保持率受样本噪声影响，可以出现桶间回升。

## 项目结构

```
src/
  types.mbt        Grade / Timestamp / CardState / Phase
  log.mbt          ReviewEvent / ReviewLog / JSONL
  scheduler.mbt    Scheduler trait
  sm2.mbt          SuperMemo 2
  fsrs.mbt         FSRS-5 公式实现
  leitner.mbt      Leitner 盒子（对照基线）
  replay.mbt       重放与跨调度器对比
  simulate.mbt     未来负载模拟
  stats.mbt        卡片统计与保留率曲线
cmd/recall/
  main.mbt         CLI
```

详细 API 见 [API.md](API.md)。

## 背景资料

- P. A. Woźniak, *Optimization of learning* (1990) — SM-2 原始论述
- Ye et al., *FSRS: A modern, efficient spaced repetition scheduler* (2023)
- Anki 手册：Deck Options / FSRS 章节

## License

Apache-2.0，见 [LICENSE](LICENSE)。



