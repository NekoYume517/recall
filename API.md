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
/// 学习理论里的"成功回忆"阈值：**非 Again 即成功**。
/// 与 SM-2 的契约一致（q < 3 才算失败，Hard 的 q=3 是成功）；
/// 全项目统一用这个谓词，"是否记住"只有这一个定义。
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

### ⚠️ `grade` 字段是有损归一化的

`Grade` 是 4 档枚举，但 JSON 里的 `grade` 是 0..5 的整数：

```
from_int:  0 → Again, 1|2 → Hard, 3 → Good, 4|5 → Easy
to_int:    Again=0, Hard=2, Good=3, Easy=5
```

因此 **`"grade":4` 读入后写回会变成 `"grade":5`**（两者都归一化为 Easy，输出时用 `Easy` 的代表值 5）。

这**不是 bug**，是「4 档枚举 ↔ 6 值整数」的固有映射。但写往返测试时要注意：

- ❌ 「JSONL 往返逐字节一致」——对含 `grade:4` 的输入会失败
- ✅ 「往返**幂等**」——第 2 次和第 3 次序列化完全一致
- ✅ 「只有 `grade` 字段变化，其余字段逐字节不变」

`elapsed_days` 同理：`0` 与 `0.0` 的文本形式可能不同，按浮点比较而非字符串比较。

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
q 的映射（唯一权威定义，不要再自己发明）:
    Again → 2
    Hard  → 3
    Good  → 4
    Easy  → 5

答错判定用 q < 3（即只有 Again 算答错）:

q < 3（答错）:
    repetitions = 0
    interval_days = 1.0
    （EF 仍按下面的公式更新）

q >= 3（答对）:
    repetitions += 1
    if repetitions == 1: interval = 1
    elif repetitions == 2: interval = 6
    else: interval = round(interval_prev * EF)

EF 更新（每次复习都做，用更新前的 EF 算间隔）:
    EF = EF + (0.1 - (5-q) * (0.08 + (5-q) * 0.02))
    EF = max(1.3, EF)
```

**注意两个容易搞错的点：**
1. `Grade::to_int` 的返回值（Again=0/Hard=2/Good=3/Easy=5）**不是** SM-2 的 `q`。`q` 必须用上面这张表单独映射。
2. `interval` 用**上一次的 EF** 算，然后再更新 EF。

### SM-2 权威参考值（手算 + 独立实现双重核对，测试必须匹配）

从新卡 `EF=2.5, reps=0` 开始：

| 输入序列 | 每次的 interval（天） | 每次后的 EF |
|---|---|---|
| Good, Good, Good, Good, Good | 1, 6, 15, 38, 95 | 2.5, 2.5, 2.5, 2.5, 2.5 |
| Easy, Easy, Easy | 1, 6, 16 | 2.6, 2.7, 2.8 |
| Hard, Hard, Hard | 1, 6, 13 | 2.36, 2.22, 2.08 |
| Good, Good, Again, Good | 1, 6, 1, 1 | 2.5, 2.5, 2.18, 2.18 |

验证 `Good, Good, Good` 第三个间隔：`round(6 * 2.5) = 15`。
验证 `Easy` 第一个 EF：`2.5 + (0.1 - 0*(0.08+0*0.02)) = 2.6`。
验证 `Hard` 第一个 EF：`q=3`，`2.5 + (0.1 - 2*(0.08+2*0.02)) = 2.5 + (0.1-0.24) = 2.36`。
验证 `Again` 的 EF（**易错**）：`q=2`，`2.5 + (0.1 - 3*(0.08+3*0.02)) = 2.5 + (0.1-0.42) = 2.18`。
（若误把 Again 当 `q=0`，会得到 `2.5 + (0.1-0.9) = 1.7`——这是错的，因为 `q=0` 不在映射表内。）

`@math.round` 是 half-up：`round(2.5)=3`、`round(37.5)=38`。

### 3.2 FSRS-style `src/fsrs.mbt`

**注意：实现 FSRS-5 的公开公式，但参数用给定默认值，不实现训练。**

```moonbit
pub(all) struct Fsrs {
  w : Array[Double]         // 21 个权重，默认用 FSRS-5 官方默认值
  desired_retention : Double // 默认 0.9
}

pub fn Fsrs::new() -> Fsrs
pub fn Fsrs::with_params(w : Array[Double]) -> Fsrs

// 权重验证套件（src/weight_validation.mbt）
pub(all) struct FsrsWeightIssue {
  index : Int      // 出问题的权重下标（-1 = 整体性问题）
  value : Double   // 读到的值
  why : String     // 人话解释
}
pub(all) enum FsrsWeightCheck {
  Valid
  Invalid(Array[FsrsWeightIssue])   // 多个问题全部收集
}
pub fn validate_fsrs_weights(w : Array[Double]) -> FsrsWeightCheck
pub fn validate_fsrs_semantics(w : Array[Double]) -> FsrsWeightCheck
pub fn validate_fsrs_reference() -> FsrsWeightCheck
pub fn Fsrs::with_params_checked(w : Array[Double]) -> Result[Fsrs, String]

pub impl Scheduler for Fsrs
```

**`with_params` 与 `with_params_checked` 的分工**：

- `with_params`：宽容版。长度不足 21 时静默回退官方默认——现有 CLI 路径依赖这个行为（用户看不懂权重错误时至少能跑）。
- `with_params_checked`：严格版。结构（长度/有限性/逐项范围）+ 语义（S₀ 单调、Good×5 不爆炸、评分敏感性）两关全过才返回，否则 `Err` 带全部问题清单。**新代码建议用这个**——权重训练器、批量实验等场景下，静默回退会把"权重没生效"伪装成"结果不显著"。

`validate_fsrs_reference` 不接受参数：它验证的是官方默认权重下全部公式常量的联立锚点（R(S,S)=0.9 四评分同时成立、间隔自检 I(S,0.9)=S、成功/遗忘路径的独立复算值）。任何一处系数抄错或符号搞反都会打破联立——这是比逐公式测试更难绕过的自检。锚点期望值用 Python 独立复算（零共享代码），容差 1e-9。

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

难度更新（**三个易错点都标在下面**）：
  delta_D = -w[6] * (g - 3) * (10 - D) / 9
      ⚠️ 末尾的 (10-D)/9 是 linear damping，**不能省**。
         省掉后 delta_D 与当前难度无关，D=8 连续 Again 第一次就顶到 10
         且再也降不下来；带阻尼是 8.62→9.04→9.33→9.52→9.64 平滑收敛。
         难度失去分辨率会系统性高估难卡的间隔增长。

  D' = D + delta_D
  D'' = w[7] * D_0(4) + (1 - w[7]) * D'
      ⚠️ mean reversion 的目标是 **D_0(4) = 3.2245**，不是 w[4] = 7.1949。
         官方 py-fsrs 参考实现用 D_0(4)。两者差 3.97，虽然 w[7]=0.0046
         使单步影响只有 0.018，但方向性错误会累积。
  D'' 截断到 [1, 10]

成功回忆的稳定性增长（**用更新后的新 D，不是旧 D**）：
  S' = S * (1 + exp(w[8]) * (11 - D_new) * S^(-w[9])
             * (exp(w[10] * (1 - R)) - 1)
             * (w[15] if g==2 else 1)
             * (w[16] if g==4 else 1))
      ⚠️ 官方的顺序是「先更新 D，再用新 D 算 S」。用旧 D 会系统性低估约 1 天。

遗忘后的稳定性：
  S' = w[11] * D^(-w[12]) * ((S+1)^w[13] - 1) * exp(w[14] * (1 - R))

下次间隔：
  I = S / FACTOR * (desired_retention^(1/DECAY) - 1)
  至少 1 天，四舍五入，**并且必须夹到 max_interval_days() = 36500（100 年）**

  ⚠️ 不夹上限的后果（真实 bug）：
     FSRS 连续 Easy 到第 46 次，interval 会到 4.19e14 天，
     `now + interval*86400` 超过 Int64 上限，due **回绕成负数**。
     due 为负 → is_due() 永远 true → 卡片永久到期，replay/simulate/stats 全崩。
     因此 `add_days()` 也必须夹住超限、负数和 NaN。
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

### 5.1 负载优化建议器 `src/advice.mbt`

回答"我想在 D 天内把积压控制住，每天最多能学几张新卡"。

```moonbit
pub(all) struct AdviceRequest {
  days : Int32                       // 建议窗口
  review_limit : Int32               // 每天复习上限，0 = 无限
  desired_retention : Double
  /// 评分策略**工厂**：每次模拟调用一次，新建独立随机流的实例。
  /// 不能放闭包实例——LCG 有状态，多次 probe 会互相污染随机流
  /// （这正是"同输入必须同输出"被破坏的真实案例，见 git 历史）。
  policy_factory : () -> (CardState) -> Grade
  seed : Int64                       // 建议可复现，种子是配置的一部分
  target_backlog : Int32             // 窗口结束时允许的最大积压，0 = 清零
}

pub(all) struct AdviceResult {
  new_per_day : Int32                // 推荐的每日新卡数
  simulation : SimResult             // 该速率下的完整模拟
  final_backlog : Int32
  next_step_backlog : Int32?         // 多学 1 张的积压（展示"为什么"）
  search_lo : Int32
  search_hi : Int32
  summary : String                   // 一句话结论
}

pub fn AdviceRequest::default() -> AdviceRequest
pub fn load_advice(s : AnyScheduler, req : AdviceRequest) -> AdviceResult
pub fn AdviceRequest::to_config(self, new_per_day : Int32) -> SimConfig
pub fn probe_final_backlog(s : AnyScheduler, req, new_per_day : Int32) -> Int32
```

方法：**模拟搜索（二分）**，不是解析解——积压动力学非线性（Again →
间隔回退 → 更多到期 → 评分策略感知逾期更悲观），解析近似会漏掉
"积压自我强化"。模拟器的确定性让搜索结果可复现。

三个诚实分支：
- 连 0 张新卡都清不了存量 → 建议 0，summary 明说"存量太大"
- 上界内绰绰有余 → 直接返回 review_limit，提示可以调大上限
- 反直觉行为被自然捕捉：**学太快反而积压**（超过消化能力后，每天
  塞得越多、未复习的卡积得越多）——这正是必须用模拟而非公式的证据

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
pub fn retention_curve(log : ReviewLog, buckets : Int) -> Array[(Double, Double)]
  // (elapsed_days_bucket, retention_rate)
```

`retention_curve` 是验证实现是否合理的**关键测试点**：理论曲线应随 elapsed 增加而单调下降。

## 7. CLI `cmd/recall/main.mbt`

```
recall replay   --log <file.jsonl> --scheduler sm2|fsrs|leitner [--json]
recall compare  --log <file.jsonl> --a sm2 --b fsrs
recall simulate --scheduler fsrs --days 90 --new-per-day 20 --review-limit 200 --policy realistic
recall advice   --scheduler fsrs --days 90 --review-limit 200 --target-backlog 0 [--policy realistic] [--retention 0.9] [--seed N]
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
