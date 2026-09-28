# recall — API 契约

> **这是实现依据，不得更改签名。** 内部实现自由，但这些公开 API 必须存在且签名一致。

模块名：`moonbit-hack/recall`，库包：`src`，CLI 包：`cmd/recall`。

## 1. 基础类型 `src/types.mbt`

```moonbit
/// 评分：0=完全忘记，1=困难，2=犹豫，3=良好，4=轻松，5=完美
pub(all) enum Grade {
  Again      // 0
  Hard       // 1-2
  Good       // 3
  Easy       // 4-5
} derive(Eq, Debug)

pub fn Grade::to_int(self : Grade) -> Int
pub fn Grade::from_int(n : Int) -> Grade
/// 学习理论里的"成功回忆"阈值：>= 3
pub fn Grade::is_pass(self : Grade) -> Bool

/// 秒级时间戳（Unix epoch），避免浮点
pub type Timestamp = Int64

/// 卡片记忆状态
pub(all) struct CardState {
  card_id : String
  stability : Double        // S：保持天数
  difficulty : Double       // D：1..10
  reps : Int                // 成功复习次数
  lapses : Int              // 遗忘次数
  last_review : Timestamp
  due : Timestamp
  interval_days : Double
  phase : Phase
} derive(Debug)

pub(all) enum Phase {
  New
  Learning
  Review
  Relearning
} derive(Eq, Debug)
```

## 2. 复习日志 `src/log.mbt`

**核心设计**：日志是唯一真相来源（source of truth），状态由重放得到。

```moonbit
pub(all) struct ReviewEvent {
  card_id : String
  reviewed_at : Timestamp      // 实际复习时刻
  due_at : Timestamp           // 当时系统认为的到期时间（用于计算 overdue）
  grade : Grade
  elapsed_days : Double        // 距上次复习的天数；首次为 0
}

pub(all) struct ReviewLog {
  events : Array[ReviewEvent]
}

pub fn ReviewLog::new() -> ReviewLog
pub fn ReviewLog::push(self : ReviewLog, ev : ReviewEvent) -> Unit
pub fn ReviewLog::length(self : ReviewLog) -> Int

/// 按 card_id 分组并按时间排序
pub fn ReviewLog::by_card(self : ReviewLog) -> Map[String, Array[ReviewEvent]]

/// JSONL 序列化
pub fn ReviewLog::to_jsonl(self : ReviewLog) -> String
pub fn ReviewLog::from_jsonl(text : StringView) -> Result[ReviewLog, LogError] raise

pub(all) suberror LogError {
  BadLine(line_no : Int, reason : String)
  BadTimestamp(line_no : Int, raw : String)
} derive(Eq, Debug)
```

JSONL 每行格式（**字段名固定**）：

```json
{"card_id":"c1","reviewed_at":1700000000,"due_at":1699999000,"grade":3,"elapsed_days":1.0}
```

## 3. 调度器接口 `src/scheduler.mbt`

```moonbit
pub trait Scheduler {
  /// 调度器名字，用于 CLI 和报告
  name(Self) -> String

  /// 新卡初始化
  init(Self, card_id : String, now : Timestamp) -> CardState

  /// 应用一次复习，返回新状态
  review(Self, state : CardState, grade : Grade, now : Timestamp) -> CardState

  /// 当前可提取性 R(t,S)，t 为距上次复习天数
  retrievability(Self, state : CardState, now : Timestamp) -> Double

  /// 目标保持率（FSRS 用，SM-2 返回固定值）
  desired_retention(Self) -> Double
}
```

**必须实现三个调度器**，且都能通过同一个 trait 调用：

### 3.1 SM-2 `src/sm2.mbt`

经典 SuperMemo 2。

```moonbit
pub(all) struct Sm2 {
  ease_factor : Double      // 默认 2.5，下限 1.3
  interval_days : Double
  repetitions : Int
}

pub fn Sm2::new() -> Sm2

pub impl Scheduler for Sm2
```

规则（**严格按此实现**）：

```
grade < 3（答错）:
    repetitions = 0
    interval_days = 1.0
    （EF 不变）

grade >= 3（答对）:
    repetitions += 1
    if repetitions == 1: interval = 1
    elif repetitions == 2: interval = 6
    else: interval = round(interval_prev * EF)

EF 更新（每次复习都做）:
    q = grade 映射到 0..5（Again→2, Hard→3, Good→4, Easy→5）
    EF = EF + (0.1 - (5-q) * (0.08 + (5-q) * 0.02))
    EF = max(1.3, EF)
```

### 3.2 FSRS-style `src/fsrs.mbt`

**注意：实现 FSRS-5 的公开公式，但参数用给定默认值，不实现训练。**

```moonbit
pub(all) struct Fsrs {
  w : Array[Double]         // 21 个权重，默认用 FSRS-5 官方默认值
  desired_retention : Double // 默认 0.9
}

pub fn Fsrs::new() -> Fsrs
pub fn Fsrs::with_params(w : Array[Double]) -> Fsrs

pub impl Scheduler for Fsrs
```

公式（**核心必做**）：

```
遗忘曲线：
  R(t, S) = (1 + FACTOR * t / S) ^ DECAY
  其中 DECAY = -0.5, FACTOR = 19/81

初始稳定性（首次评分 g）：
  S_0(g) = w[g-1]                    // g ∈ 1..4

初始难度：
  D_0(g) = w[4] - exp(w[5] * (g - 1)) + 1
  D_0 截断到 [1, 10]

难度更新：
  D' = D - w[6] * (g - 3)
  D'' = mean_reversion(w[4], D')      // w[7] 控制回归强度
  D'' 截断到 [1, 10]

成功回忆的稳定性增长：
  S' = S * (1 + exp(w[8]) * (11 - D) * S^(-w[9])
             * (exp(w[10] * (1 - R)) - 1)
             * (w[15] if g==2 else 1)
             * (w[16] if g==4 else 1))

遗忘后的稳定性：
  S' = w[11] * D^(-w[12]) * ((S+1)^w[13] - 1) * exp(w[14] * (1 - R))

下次间隔：
  I = S / FACTOR * (desired_retention^(1/DECAY) - 1)
  至少 1 天，四舍五入
```

要求：**公式必须逐项可核对**，每一项注释对应的 w 下标。

### 3.3 Leitner `src/leitner.mbt`

最简单的盒子模型，作为对照基线。

```moonbit
pub(all) struct Leitner {
  boxes : Int               // 默认 5
  intervals : Array[Double] // 每盒间隔天数，默认 [1, 2, 4, 8, 16]
}

pub fn Leitner::new() -> Leitner
pub impl Scheduler for Leitner
```

规则：答对进下一盒，答错回第 1 盒。

## 4. 重放引擎 `src/replay.mbt`

```moonbit
pub(all) struct ReplayResult {
  final_states : Map[String, CardState]
  /// 每次事件后的状态快照（用于对比不同调度器）
  snapshots : Array[(Timestamp, String, CardState)]
  /// 统计
  total_reviews : Int
  total_lapses : Int
  /// 实际间隔 vs 理想间隔的偏差
  interval_error_days : Double
}

/// 用指定调度器重放整份日志
pub fn replay(log : ReviewLog, scheduler : Scheduler) -> ReplayResult

/// 对比两个调度器在同一日志上的表现
pub(all) struct Comparison {
  a_name : String
  b_name : String
  a_total_interval : Double
  b_total_interval : Double
  a_lapses : Int
  b_lapses : Int
  /// 每个卡片的最终间隔差
  per_card : Array[(String, Double, Double)]
}

pub fn compare(log : ReviewLog, a : Scheduler, b : Scheduler) -> Comparison
```

## 5. 模拟器 `src/simulate.mbt`

回答"如果我每天学 N 张新卡，三个月后积压多少"。

```moonbit
pub(all) struct SimConfig {
  days : Int                    // 模拟天数
  new_per_day : Int             // 每天新增卡数
  review_limit : Int            // 每天最多复习数，0 = 无限
  desired_retention : Double
  /// 模拟用户行为：给定到期卡和当前状态，返回评分
  grade_fn : (CardState) -> Grade
}

pub(all) struct SimDay {
  day : Int
  new_cards : Int
  due_cards : Int
  reviewed : Int
  backlog : Int
  retained : Int
}

pub(all) struct SimResult {
  days : Array[SimDay]
  total_reviews : Int
  max_backlog : Int
  final_backlog : Int
}

pub fn simulate(scheduler : Scheduler, config : SimConfig) -> SimResult

/// 一组常用评分策略，供 CLI 使用
pub fn grade_policy(name : StringView) -> ((CardState) -> Grade)
```

`grade_policy` 至少支持：`optimistic`（总是 Good）、`realistic`（按 retrievability 概率抽样，用确定性伪随机）、`pessimistic`（按难度倾向 Hard/Again）。

**确定性要求**：模拟必须可复现。伪随机用固定种子的 LCG，不要用系统随机。

## 6. 统计 `src/stats.mbt`

```moonbit
pub(all) struct CardStats {
  card_id : String
  reviews : Int
  lapses : Int
  mean_interval : Double
  max_interval : Double
  retention_rate : Double       // 成功复习 / 总复习
}

pub fn compute_stats(log : ReviewLog) -> Array[CardStats]
pub fn retention_curve(log : ReviewLog, buckets : Int) -> Array[(Double, Double]>
  // (elapsed_days_bucket, retention_rate)
```

`retention_curve` 是验证实现是否合理的**关键测试点**：理论曲线应随 elapsed 增加而单调下降。

## 7. CLI `cmd/recall/main.mbt`

```
recall replay   --log <file.jsonl> --scheduler sm2|fsrs|leitner [--json]
recall compare  --log <file.jsonl> --a sm2 --b fsrs
recall simulate --scheduler fsrs --days 90 --new-per-day 20 --review-limit 200 --policy realistic
recall stats    --log <file.jsonl>
recall curve    --log <file.jsonl> --buckets 10
```

退出码：0 成功，1 数据错误，2 用法错误。

## 8. 测试要求

- SM-2 表格测试：给定序列，逐次间隔必须匹配手算值
- FSRS：`R(t=S, S) ≈ 0.9`（浮点容差 1e-6）
- 单调性属性测试：
  - 同一卡片，Good 的间隔 ≥ Hard 的间隔
  - 间隔随 reps 单调不减
  - EF 永不低于 1.3
  - retention_curve 单调递减
- 重放确定性：同一日志跑两次结果完全一致
- JSONL 往返
- 模拟：new_per_day=0 时 backlog 单调不增
