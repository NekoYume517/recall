# recall — API 契约

> **这是实现依据，不得更改签名。** 内部实现自由，但这些公开 API 必须存在且签名一致。

模块名：`NekoYume517/recall`，库包：`src`，CLI 包：`cmd/recall`。

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
  reps : Int32              // 见下方「reps 的语义按调度器分派」
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

### `reps` 的语义按调度器分派（2026-11-17 审计：把这条写清楚）

| 调度器 | `reps` 是什么 | 答错时 |
|---|---|---|
| **FSRS** | 累计成功复习次数（`lapsed` 不递增它） | 不变 |
| **Leitner** | 累计答对次数（`is_recalled` 为真才 +1） | 不变 |
| **SM-2** | **`repetitions`：连续成功次数** | **清零** |

SM-2 的 `repetitions` 是 SM-2 公式的一部分（`reps=0/1/2` 分别对应
`interval=1/1/6`，之后才走 `round(prev × EF)`），所以 `Sm2::review`
（`src/sm2.mbt`）在 `q < 3`（只有 Again）时把它归零——这就是「连续成功次数」
而不是「累计成功次数」。**按「累计」使用 `reps` 的代码在 SM-2 上会恒得 0**，
`lapses` 才是跨调度器一致的遗忘计数。公开 `CardState` 的 `reps` / `lapses`
抵达 `Int32.MAX` 后再次递增会饱和在该上限，不回绕成负数；SM-2 遗忘时
`reps` 清零的算法语义不变（`src/scheduler_counter_overflow_regression_test.mbt` 锁定）。

同一个字段三种语义，因此 `replay` 的表格、Anki 导出的 `reps` 列、
`compare` 的逐卡数字**不能跨算法比较**（与 `difficulty` 的
「FSRS=D / SM-2=EF / Leitner=盒号」同一约定）。

## 2. 复习日志 `src/log.mbt`

**核心设计**：日志是唯一真相来源（source of truth），状态由重放得到。

```moonbit
pub(all) struct ReviewEvent {
  card_id : String
  reviewed_at : Timestamp      // 实际复习时刻
  due_at : Timestamp           // 当时系统认为的到期时间（用于计算 overdue）
  grade : Grade
  elapsed_days : Double        // 距上次复习的天数；首次为 0
  grade_raw : Int64            // JSON 原始评分整数（无损日志）；new 构造取代表值
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

### 两个「静默接受」的行为（第二十一轮 RC-21-4b，2026-11-29）

这两条一直存在，但此前**没有任何文档写过**——读入口对它们返回 exit 0，读者只能
去读实现才知道。既然它们是行为，就得写下来，并各配一条断言
（`cmd/recall/jsonl_documented_behaviors_wbtest.mbt`）。

**1）重复键：后者覆盖前者（last-wins）。**

```json
{"card_id":"first","card_id":"second","reviewed_at":1700000000,…}
```

→ 解析后 `card_id == "second"`，输出里只有 `second`。

这是**有意**的，理由有两条：

- 与主流 JSON 解析器惯例一致（`JSON.parse` 等等都是 last-wins），本仓库用
  `@json.parse` 落到 `Map`，重复键天然覆盖；
- 与本 CLI 对**参数**的 last-wins 一致（`--log a --log b` 取 `b`），同一个工具
  里不该有两套「重复怎么办」的语义。

⚠️ 推论：**重复的 `reviewed_at` 也按后者算**。
`{"reviewed_at":1,"reviewed_at":1700000000,…}` 事件时间是后者。写日志的上游若
可能产出重复键，应在**自己那一侧**做去重——本解析器不会报错。

**2）附加字段（含任意嵌套）不影响事件内容；解析器拒绝时整行作废。**

本仓库**不承诺任何嵌套深度上限**——那是 `@json.parse` 实现的属性，可能在版本间
变化，也可能根本不存在（本地 `0.1.20261102` 约 1024 层开始拒；CI 的 `latest`
实测 8192 层全部可解析、没有上限）。把「第 N 层会被拒」写进契约，等于承诺一件
自己控制不了的事。

本仓库承诺的是下面两条，**与工具链有没有上限无关**：

**① 未被记录的附加字段（含任意嵌套）不影响事件内容。**
读入口只按已知字段名取值，其余键一律无视。因此：

```
{"card_id":"c",…,"elapsed_days":1}                        ← 基线
{"card_id":"c",…,"elapsed_days":1,"x":[[[…1…]]]}          ← 追加 64 层嵌套
```

两者的 `stats` 报表除首行文件路径外**逐行相同**（实测：扁平字符串 / 扁平数字 /
64 层嵌套 / 混合形状，四种附加字段形状全部与基线一致）。

**② 解析器拒绝某行时，整行被判非法——不会「部分成功」。**
不存在「裁掉读不懂的字段后继续」这种中间态：

- 事件被接受 → `exit 0`，且报表里能数到这条事件；
- 整行被拒 → `exit 1`，`数据错误: 第 1 行解析失败 — 不是合法 JSON`，
  **stdout 为空**（不许半截输出）。

**怎么验证**（不依赖上限数值）：喂一个很深的行（如 5000 层），判据是
「要么 `exit 0` 且事件被收下，要么 `exit 1` 且 stdout 为空」——两种工具链形态下
都成立。**不要**断言「某个深度必须被拒」：无上限的工具链上永不越界，那条断言
必然随工具链版本飘。

补充：若某工具链确实有上限，它算的是**绝对嵌套深度**（从顶层 `{` 起算），
不是你那个附加字段自己的深度。这个细节同样不是本仓库的契约，只是解释「为什么
同一份报表在有无上限的工具链上可能一个收下、一个整行拒收」。

### `grade` 字段：调度归一化 + 无损日志（RJ-R / RJ-1b）

`Grade` 是 4 档枚举，但 JSON 里的 `grade` 是 0..5 的整数：

```
from_int:  0 → Again, 1|2 → Hard, 3 → Good, 4|5 → Easy
to_int:    Again=0, Hard=2, Good=3, Easy=5
```

**调度语义**按归一化后的枚举驱动（`1` 与 `2` 的调度行为相同是
FSRS/SM-2 的定义）；**日志保真**由 `grade_raw` 保证：from_jsonl 记录
JSON 原文（round 后的整数），to_jsonl 原样写回。因此：

- ✅ 「JSONL 往返逐字节一致」——含 `grade:1/4` 的输入也原样写回
  （`1→1`、`4→4`，不再是旧的 `1→2`、`4→5` 有损行为）
- ✅ `grade_raw` 是 Int64，能无损承载到 ±2^53（2026-11-08 审计 RJ-1b：
  旧版用 Int32，`"grade":2500000000` 会饱和成 2147483647）
- ❌ `|grade| > 2^53`（Double 精确整数域之外）的输入在解析时报数据
  错误，而不是静默改值。**纯整数字面按原文判容量**（RJ-A2，2026-11-10
  审计）：`9007199254740993`（2^53+1）在 Double 上恰好等于 2^53，
  只比解析后的值会让它蒙混过关、首次往返被改写成 ...992，因此对
  「无小数点/指数的整数写法」额外做字面比较（`-?\d+` 且绝对值 > 2^53
  即拒收）。
- ✅ 小数 `grade` 按「评分是整数刻度」的契约 round 后写回该整数
  （`4.6 → 5`）

`elapsed_days` 同理注意：`0` 与 `0.0` 的文本形式可能不同，按浮点比较而非字符串比较。

**写出口的同一份判断**（2026-11-17 第十三轮审计，P2）：`elapsed_days` 的
有限性守卫原本只在读入口（`field_double`：非有限 → `BadLine`）。两个公开
构造器只把**负数**夹到 0，非有限值（`NaN` / `±Infinity`）原样进事件，
`to_jsonl` 再把它们原样写成 `NaN` / `Infinity`——**不是 JSON 字面量**，
产出的是本仓库自己也读不回来的文件。现在 `event_to_json` 是全部事件的
**序列化出口**（`ReviewEvent` 是 `pub(all)`，直构字段可绕过构造器），非有限
`elapsed_days` 一律落 **0**——下游对「非有限」与「0」的判定完全一致
（只采用有限 `elapsed_days > 0.0` 的字面值，否则按时间戳回推），因此语义零变化、
输出恒可被 `from_jsonl` 读回（`src/log_nonfinite_elapsed_serialization_regression_test.mbt` 锁定）。
2026-11-19 同族补全：`pub(all)` 直构的**负值**也在写出口落 0，与两个构造器和
JSONL 读入口的规范化一致，避免 `to_jsonl → from_jsonl` 把负值改成 0 的往返漂移
（`src/log_negative_elapsed_serialization_regression_test.mbt` 锁定）。

`grade_raw` 的写出口同样受 JSON 精确整数域约束：公开构造器或 `pub(all)` 字段给出
`|grade_raw| > 2^53` 时，改用 `grade` 的代表分（0/2/3/5），避免 Double 舍入后写出自家
读入口拒收的大整数；`[-2^53, 2^53]` 内仍逐字节保留原文
（`src/log_wide_grade_serialization_regression_test.mbt` 锁定）。

`reviewed_at` / `due_at` 的 JSONL 合法域与读入口一致：
`[-62135596800, 253402300799]`（0001-01-01 至 9999-12-31）。该域内的整数都
小于 2^53，合法 JSONL 的逐字节往返覆盖两个端点；`grade_raw` 的 ±2^53 边界也
保持可读回。公开构造器与 `pub(all)` 字段虽能承载全域 Int64 时间戳，但超出上述
年域的事件不属于可序列化 JSONL 的合法输入：写出口不静默夹改历史时间，读入口
会按 `BadTimestamp` 拒收。Int64 全域仍可只用于内存调度与 ISO8601 工具。

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
    EF = max(1.3, EF)        // 非有限（NaN / ±Inf）也按 1.3 继续
```

**EF 的三处守卫是同一套规则**（`sm2_ease_or_floor`，2026-11-13 审计 D2）：
`with_ease` 的构造夹取、`init` 写进 `CardState.difficulty` 的初值、`review`
读外部状态的防守。修复前三处都写成比较式（`x < 1.3`），而 `NaN < 1.3` 为
false —— NaN 从守卫中间穿过去，`round(prev_interval × NaN)` 落到 1 天下限，
**这张卡从此每天到期一次**（实测 `difficulty=NaN` 时 `iv1=1 iv3=1`，
按 1.3 继续则是 `1 / 6 / 8`）。`CardState` 是 `pub(all)`，库级可达；
可达性论证与 R-6（FSRS 非有限权重）同型。

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
（记一笔：Python 的 `round` 是 half-to-even / 银行家舍入，`round(2.5)=2`。
因此间隔恰好落在 `k+0.5` 时本实现可能比 py-fsrs 多 1 天。这是**已声明的
刻意差异**——half-up 是直观的"四舍五入"，且与 SM-2 一侧的 `@math.round`
一致；改它会让同一份代码里两套调度器用两套舍入。见
`docs/implementation.md` 的同名小节。）

### 3.2 FSRS-style `src/fsrs.mbt`

**注意：实现 FSRS-5 的公开公式，但参数用给定默认值，不实现训练。**

```moonbit
pub struct Fsrs {
  priv w : Array[Double]   // 实例独占，外部不可读写或直接构造
  desired_retention : Double // 默认 0.9
}

pub fn Fsrs::weights(self : Fsrs) -> Array[Double] // 独立副本
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

权重封装：请通过构造器创建 `Fsrs`，原先 `.w` 读取迁移为 `.weights()`。接收数组的构造器复制输入，快照也可独立修改，不影响调度器。低级公式函数仍接收原始数组，要求至少 19 项且由调用方负责验证。

**`with_params` 与 `with_params_checked` 的分工**：

- `with_params`：宽容版。长度不足 19 时回退官方默认；至少 19 项则复制全部输入，不校验有限性、范围或模型版本。底层初始稳定性仍会夹到 0.1 天，**成功 / 遗忘 / 同日三条稳定性路径的非有限结果（NaN 与 ±Inf）同样落到 0.1 天**（R-6、D3）。需要明确拒绝无效参数时使用 checked 版。
- `with_params_checked`：严格版。接受原生 19 项及本库历史兼容 21 项；后两项只校验有限性、不参与公式。初始稳定性 w0..3 要求 [0.1,100]，避免校验通过后被静默抬高。结构（长度/有限性/逐项范围）+ 语义（S₀ 单调、Good×5 不爆炸、评分敏感性）两关全过才返回，否则 `Err` 带全部问题清单。**新代码建议用这个**——权重训练器、批量实验等场景下，静默回退会把"权重没生效"伪装成"结果不显著"。

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

同日再次复习（非首次，距离上次复习不足 1 天）：
  S' = max(0.1, S * exp(w[17] * (g - 3 + w[18])))
  同时正常更新 D；首次评分仍使用初始稳定性。

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

成功回忆的稳定性增长（使用复习前的 D）：
  S' = S * (1 + exp(w[8]) * (11 - D) * S^(-w[9])
             * (exp(w[10] * (1 - R)) - 1)
             * (w[15] if g==2 else 1)
             * (w[16] if g==4 else 1))
      D' 与 S' 从同一份旧状态独立计算，新 D 仅保存到输出状态。

遗忘后的稳定性（FSRS-5）：
  raw = w[11] * D^(-w[12]) * ((S+1)^w[13] - 1) * exp(w[14] * (1 - R))
  cap = S / exp(w[17] * w[18])      // 短期上限（enable_short_term 开时）
  S'  = max(0.1, min(raw, cap))

  ⚠️ 上限是 **S / exp(w17·w18)**，不是裸 S。`min(raw, S)` 是 FSRS-4.5 的写法；
     FSRS-5 只在短期调度**关闭**时才用它。本仓库的 `step` 对 elapsed < 1
     是用 w17/w18 做短期更新的（即短期开着），所以两条分支必须同一个假设。
     默认权重下 exp(w17·w18) = 1.40777，用错上限会让遗忘后的稳定性虚高最多
     40.8%（D=3, S=22.75, R=0.05: 22.75 vs 官方 16.16），间隔随之偏长。
     官方参考：py-fsrs 5.1.3 `Scheduler._next_forget_stability`。

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

**`rating` 的定义域只有一处**（2026-11-17 第十三轮审计，P3）：FSRS 的评分刻度
是 `1..4`，接收 `rating` 的公开公式入口（`initial_stability` /
`initial_difficulty` / `next_difficulty` / `success_chain` / `step`）一律经
`clamp_rating` 夹到该区间，越界值按最近的端点处理。修复前只夹了前两个，于是
`next_difficulty(w, 5.0, 0) = 7.4146…`（按 g=0 算）而 `(w, 5.0, 1) = 6.6070…`
——同一张卡的「初始难度」按 Again 算、「难度推进」按域外形参算。调度器路径
不可达（`fsrs_rating` 只产出 1..4，夹取是恒等变换），库级直接调用可达。

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

**盒数只有一个来源**（2026-11-17 审计，P3）：`intervals` 与 `boxes` 都是
`pub(all)` 字段，手工构造时可能不同步。`effective_boxes()` 取
`min(max(boxes, 1), max(intervals.length(), 1))`，`review` 的盒号夹取与
`interval_of` 的间隔查表**共用这一个上界**。修复前两处各用各的，`{ boxes: 10, intervals: [1.0] }`
连续 Good 后得到 `difficulty = 6`（盒 6）而 `interval_days = 1.0`（盒 1 的间隔）
——同一张卡两个字段自相矛盾（红灯实测 `box=6 interval=1`）。

**空间隔表**（2026-11-17 第十三轮审计，P1）：`{ boxes: n, intervals: [] }` 是
上一条论证的盲区——`effective_boxes()` 对空表按「至少一盒」返回 1（盒号是
1-based），但表里没有任何一项可读，修复前 `interval_of` 直接读 `intervals[0]`
——**数组越界 panic**（wasm `unreachable`，进程级崩溃），`init` / `review`
第一次调用就崩。现在空表按 **1 天**兜底（与「表项为 NaN / 非正值」同一个兜底
值），退化语义因此自洽：盒 1、间隔 1 天、每天到期。判级 P1（崩溃而非错值）；
可达性仍是 `pub(all)` 直构，`with_intervals(0, [])` 会显式 `Err`。

自定义盒表请用带校验的构造器，长度不匹配直接报错，不接受两套定义：

```moonbit
pub fn Leitner::with_intervals(boxes : Int32, intervals : Array[Double])
  -> Result[Leitner, String]      // intervals.length() != boxes ⇒ Err（并复制输入）
```

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
  /// **有同刻事件的卡片数**（同一 card 内至少两条 `reviewed_at` 相等）。
  /// 同刻事件的先后由文件行序决定，换序可能改变摘要——CLI 会把它同时发到
  /// stderr（人读诊断）与 `--json` 的 `same_timestamp_groups`（机读字段，
  /// 为 0 时不写该键）。见 §17「重放确定性的边界」。
  same_timestamp_groups : Int
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

### 4.1 计划值（`scheduled`）的口径与它的已知盲区（第二十二轮 RC-22-4）

三个偏差指标（`interval_error_days` / `signed_interval_error_days` /
`late_review_ratio`）都取同一批样本，**计划值来自日志**：

```
scheduled = (due_at − 上一条事件的 reviewed_at) / 86400   首条事件无前驱，
                                                           沿用调度器初始 interval_days
```

RC-19-2 定的就是这条（此前实现取调度器自己算出的理想间隔，`due_at` 一个字节
都不参与）。三条**已签字**的边界，测试在
`src/replay_negative_plan_clamp_documented_test.mbt`：

1. **计划值晚于上次复习** ⇒ 读数对它敏感，方向可读：计划比实际晚 4 天
   ⇒ `signed = −4`（提前 4 天）。这是 RC-19-2 的守卫。
2. **计划值早于上次复习**（`due_at < 上一条 reviewed_at`）⇒ `scheduled` 按 0
   处理。该样本的偏差于是变成 `actual − 0 = actual`，即被记成**整段逾期**，
   而不是「提前 N 天」。实测：`elapsed_days = 4`、`due_at = 上次复习 + 1 天`
   （计划值 −3 天）→ `signed = +3`、`late_ratio = 1.0`，而用户实际行为是
   **提前 3 天**。**方向与幅度都错**，这是本指标目前最大的已知盲区。
3. **计划值正好等于上次复习**（计划值 0）⇒ `scheduled = 0`，该样本
   **整个不计入**（`scheduled > 0` 才收样本），读数保持 0。

第 2、3 条是**行为**，不是 bug 报告：日志里 `due_at` 早于上次复习是否合法、
以及它该记「提前 N 天」还是「当天到期」，属于产品判断，本轮不改语义。
把 `due_at` 早于上次复习 4 天与正好等于上次复习，在 CLI 上得到**逐字节相同**
的输出——这一点也写进了断言，免得下一轮把它误判成 RC-19-2 复发。
`footnote`：要区分这两者，唯一办法是消费方自己拿原始日志算
`days_between(prev.reviewed_at, ev.due_at)`；重放结果里没有这个量。

## 5. 模拟器 `src/simulate.mbt`

回答"如果我每天学 N 张新卡，三个月后积压多少"。

```moonbit
pub(all) struct SimConfig {
  days : Int                    // 模拟天数
  new_per_day : Int             // 每天新增卡数
  review_limit : Int            // 每天最多复习数，0 = 无限
  desired_retention : Double    // 目标保持率，见下方"生效范围"
  /// 模拟用户行为：给定到期卡和当前状态，返回评分
  grade_fn : (CardState) -> Grade
}

**`desired_retention` 的生效范围**（2026-10-27 修正）：该字段由
`simulate`（`AnyScheduler` 入口，CLI 与 advice 走这条）读取并施加到传入的
调度器实例上：

- **FSRS**：真正生效。间隔由它反解，因此不同的值给出不同的负载。
  取值的夹取/回退规则与 CLI `--retention` 一致（`clamp_retention`）：
  `(0,1)` 外的无效值与 NaN 回退 `0.9`，越界值夹到 `[0.5, 0.99]`。
  施加时保留实例已有的权重（`Fsrs::with_params_and_retention`）。
- **SM-2 / Leitner**：**不生效**，这是算法固有局限而非缺陷
  ——两者的 `desired_retention()` 分别固定返回 `0.9` / `1.0`，
  没有可调旋钮，字段对它们无效，配置只影响回显。

⚠️ 泛型入口 `simulate_with(s, config)` / `simulate_with_budget(s, config, limit)`
**按传入实例原样跑**，不读该字段（MoonBit 的 trait 不支持默认实现，泛型入口
无法重建任意 `T`）。需要让配置里的目标保持率生效时用 `simulate`，或先把值
施加到实例上（`AnyScheduler::with_config(s, config)`，语义上等于
`AnyScheduler::with_retention` / `Fsrs::with_retention`）。

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

/// **运行时工作预算**（2026-11-13 追加轮）：主循环累计 `Σ due_cards`
/// 超过 `work_limit` 就中止。`simulate` / `simulate_with` 等价于
/// `work_limit = Int64.MAX`（不限），因此 advice 的探测路径不受影响。
pub(all) struct SimAbort {
  day : Int32          // 中止发生的那一天（0 基）
  backlog : Int32      // 当天结束时的积压（到期但没排上）
  due_cards : Int32    // 当天的到期条数（= 当天要排序/处理的队列长度）
  work : Int64         // 中止时已累计的到期条数
  limit : Int64        // 预算
}

pub(all) enum SimOutcome {
  Completed(SimResult)
  Aborted(SimAbort)
}

pub fn simulate_with_budget[T : Scheduler](
  s : T,
  config : SimConfig,
  work_limit : Int64,
) -> SimOutcome

/// 一组常用评分策略，供 CLI 使用
pub fn grade_policy(name : StringView) -> ((CardState) -> Grade)
```

`grade_policy` 至少支持：`optimistic`（总是 Good）、`realistic`（按 retrievability 概率抽样，用确定性伪随机）、`pessimistic`（按难度倾向 Hard/Again）。

**未复习的新卡一律按 `R = 0.9` 抽样**（2026-11-17 审计，P3）。评分器只能看到
`CardState`，而 `stability` 的语义按调度器分派（FSRS=S、SM-2=间隔镜像、
Leitner=盒间隔）——`Leitner::init` 把 `stability` 写成盒 1 的间隔 1.0，
于是「尚未建立记忆」看起来像「刚复习过、记得很牢」：`simulate` 把
`interval_days` 换成真实流逝天数 0 之后，Leitner 新卡的 R 是 **1.0**，而
FSRS / SM-2 是 0.9。实测首日「记住」率（`--days 1 --new-per-day 100`）：

| 策略 | 修复前 Leitner | 修复后 Leitner | FSRS / SM-2（始终不变） |
|---|---|---|---|
| `realistic` | **100/100** | 90/100 | 90/100 |
| `pessimistic` | **74/100** | 67/100 | 67/100 |

这是「同一个用户模型对不同算法给出不同成功率」，`compare` 与 `advice` 的跨算法
结论因此不是同口径。判据用**调度器无关**的 `phase == New`（只有从未复习过才是
`New`），把它与 FSRS 的 `stability <= 0` 放在同一条规则里——**没有**给 Leitner
凭空加遗忘曲线，Leitner 调度器本身一个字没改。

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
/// **带运行时工作量预算**（第十二轮审计）：每次探测都走 `simulate_with_budget`，
/// 与 `simulate` 的第四道守卫**同一个判据**。中止时返回 `AdviceAborted`。
pub fn load_advice_with_budget(
  s : AnyScheduler,
  req : AdviceRequest,
  work_limit : Int64,
) -> AdviceOutcome
pub fn AdviceRequest::to_config(self, new_per_day : Int32) -> SimConfig
pub fn probe_final_backlog(s : AnyScheduler, req, new_per_day : Int32) -> Int32

pub(all) struct AdviceAbort {
  new_per_day : Int32     // **被中止的那一次探测**的每日新卡数（搜索量，不是用户参数）
  sim : SimAbort          // 那一天的运行时状态（与 simulate 的中止信息同一形状）
}
pub(all) enum AdviceOutcome {
  AdviceCompleted(AdviceResult)
  AdviceAborted(AdviceAbort)
}
```

`load_advice` 等价于 `load_advice_with_budget(s, req, Int64.MAX)`——与
`simulate` / `simulate_with`、`simulate_with_budget` 同一分层：库层老入口保持
「不限预算」，需要预算的调用方（CLI）走带预算的版本。

**`AdviceRequest.desired_retention` 在两条探测路径上都生效**（2026-11-21
审计）：配置 → 调度器的归一化收敛在 `AnyScheduler::with_config` 一个点上。
`probe_backlog`（→ `simulate`）与 `probe_outcome`（→ 泛型
`simulate_with_budget`，它按实例原样跑）都必须先过它。修复前后者直接吃
实例，于是同一份请求只改这个字段，搜索结果仍逐字段相同，而
`probe_final_backlog`（本文件称其为「`load_advice` 的构件」）却按新值跑。
回归：`src/advice_retention_config_regression_test.mbt`（字段生效 + 与
`simulate` 逐字段一致 + 单点代回复现同一个积压）。

方法：**模拟搜索（从上界向下逐点扫描）**，不是解析解——积压动力学非线性
（Again → 间隔回退 → 更多到期 → 评分策略感知逾期更悲观），解析近似会漏掉
"积压自我强化"。搜索也**不能二分**：积压对 `new_per_day` 非单调（实测
`f(43)=422`、`f(44)=526`、`f(45)=465`），从 `review_limit` 往下第一个
达标的 n 才是真实最大值。最坏 `O(review_limit)` 次模拟，命中即停。
模拟器的确定性让搜索结果可复现。

**这是刻意的成本/正确性取舍，不是待优化缺陷。** 精确答案需要最坏
`O(review_limit)` 次完整模拟：实测 90 天窗口下 `limit=150` 约 10s、
`limit=500` 约 136s（单次 probe 就要重跑 `O(days × cards)` 的整段模拟）。
换来的是「真实最大值」而不是「保守上界」——二分曾在 90 天 / 上限 150 /
目标 500 的配置上把 45 报成 43，少报的建议会直接低估可学容量。
CLI 是显式调用、结果逐字节可复现，秒级到两分钟的等待是可接受的代价；
测试套件不承担这个成本：回归用 15–30 天的小配置跑 `load_advice`，
原始配置只保留 probe 级证据（成本 7 次模拟），详见 `src/advice_test.mbt`
顶部说明。若将来确实需要提速，可选方向是优化 `simulate` 的单次成本
（搜索方向与上界不动）。

**CLI 的量级守卫**（2026-11-12 遗留项 A1；2026-11-13 补扫描量与运行时预算；
2026-11-27 第十九轮 RC-19-4 收 advice 的成本上限）。

`simulate` 有**三道**守卫：前两道是启动时的，第三道是运行时的。

```
卡数     = days × new_per_day                    <= 100000        （内存，启动时）
扫描量   = new_per_day × days² / 2               <= 250000000     （时间，启动时）
工作预算 = Σ_d due_cards                         <= 60000000      （时间，运行时）
```

扫描量那一项来自 `simulate_with` **每天两趟全表扫描**（找 due、统计 backlog），
所以 `Σ_d states(d) ≈ new_per_day·days²/2`。只卡卡数会漏掉它：`--days 5000
--new-per-day 20` 与 `--days 100000 --new-per-day 1` **都是 10 万张卡**，
后者实测 **300 s 零字节输出、进程不退出**（2026-11-13 审计 D1）。实测表
（`--review-limit 200`，native）：

| 配置 | 卡数 | 扫描量 | 实测 |
|---|---|---|---|
| `--days 90 --new-per-day 20`（DEMO 档） | 1 800 | `8.0e4` | 0.4 s，放行 |
| `--days 2000 --new-per-day 20` | 4 万 | `4.0e7` | 十秒级，放行 |
| `--days 20000 --new-per-day 1` | 2 万 | `2.0e8` | 6.4 s，放行 |
| `--days 5000 --new-per-day 20` | 10 万 | `2.5e8` | 分钟级（2026-11-13 那台机器 221 s），**边界值，放行** |
| `--days 100000 --new-per-day 1` | 10 万 | `5.0e9` | 修前**分钟级零输出**（实测 300 s 仍未终止）；现在 exit 2 |

边界用 `>`（`2.5e8` 本身合法），拒绝消息给按当前 `--new-per-day` 反算的
`--days` 上界（解 `n·d·(d-1)/2 <= 2.5e8`），并代回判定确认通过：

```
用法错误: simulate 的扫描量（--new-per-day × --days² ÷ 2，模拟器每天两趟全表扫描）必须 <= 250000000，
得到 1 × 100000² ÷ 2 = 4999950000（--days 100000，--new-per-day 1）
  建议: 保持 --new-per-day 1 时把 --days 降到 22361 以内（扫描量与 --days 的平方成正比，调 --days 才是最有效的一侧）
```

**第三道：运行时工作预算**（2026-11-13 追加轮）。前两道都是「启动时按三个
参数算一个数」，它们**算不出积压**——积压是运行时涌现的。决定性实测
（native release，`--days 2000 --new-per-day 20`，只改 `--review-limit`；
五组的扫描量都是 `4.0e7`）：

| `--review-limit` | 耗时 | 最终积压 |
|---|---|---|
| 20 | 9.2 s | 39 844 |
| 50 | 7.0 s | 39 275 |
| 200 | 3.1 s | 22 451 |
| 500 | 0.3 s | 0 |
| 2000 | 0.3 s | 0 |

扫描量相同、耗时差 30 倍 ⇒「`days × review_limit`」和「扫描量」都不是主导项，
**积压能不能被 `--review-limit` 消化**才是；而积压在启动时不可计算（它由调度器
给出的间隔分布与三个参数交互决定）。所以判据只能放在运行时：主循环每天累计
「当天到期条数」`Σ due_cards`（= 当天要排序/处理的队列长度，实测与耗时近似
线性：release 约 `1e6–5e6` 条/秒，`moon run` debug 约 `8e5`），超过 `6e7` 立即
中止并 exit 2。

判据**与墙钟无关**：同一配置两次运行必在同一天、同一积压处中止（`SimAbort`
逐字段可复现，`cmd/recall/simulate_budget_wbtest.mbt` 锁定），所以换机器、
换构建模式只会改变「多久到达中止点」，不改变中止点本身。

阈值两侧（本机实测）：

| 侧 | 配置 | `Σ due` | 结果 |
|---|---|---|---|
| 必须放行 | 文档里每条 `simulate`（90/20/200、90/20/50、60/20/30） | `7.7e3 – 5.2e4` | exit 0，<1 s |
| 必须放行 | 上一轮的建议值 `--days 22361 --new-per-day 1` | `4.6e5` | exit 0，0.7 s |
| 必须放行 | `--days 2000 --new-per-day 20 --review-limit 20` | `4.0e7` | exit 0，7.7 s |
| 必须拦下 | `--days 5000 --new-per-day 20 --review-limit 200` | `1.75e8` | 修前跑完要**分钟级**（2026-11-13 那台机器 release 52.8 s / debug 221 s）；现在 **数十秒量级 exit 2**（2026-11-17 本机 release 45 s）。**秒数随机器变，中止点不变** |

中止消息给两条**可执行**建议：

1. `--days` 降到中止那天之前——第 `day` 天之前的累计量必然 ≤ 预算（预算是
   那一天才超的），所以这条可证，且做了双向实测：`--days 3292` exit 0、
   `--days 3293` 在同一位置（第 3293 天、`60040991` 条）中止。
   **这条双向性质是硬契约**（判据与墙钟无关，换机器/换构建模式都不变）；
   变的只有「多久到达中止点」——2026-11-17 本机 release 实测 3292 → 44.4 s、
   3293 → 43.1 s，与 2026-11-13 那台机器的 15.0 s / 14.4 s 只差耗时、不差位置；
2. `--review-limit 0`（不限）：积压不增长时每天只处理当天到期的卡，成本回归
   线性（`--days 5000 --new-per-day 20 --review-limit 0` = `1.3e6` 条 / 1.2 s）。

```
用法错误: simulate 的运行时工作量超过预算（累计到期条数上限 60000000，判据与墙钟无关）：第 3293 天已累计 60040991 条，当天到期 51001 张、积压 50801 张，--review-limit 200 消化不了 —— 积压越堆越大，每天要在更长的队列上排序/扫描
  建议: 把 --days 降到 3292 以内（第 3292 天之前的累计量在预算内，实测该配置 exit 0）；或把 --review-limit 0（不限）——积压不再增长时成本回归线性
```

库层 `simulate_with_budget` 接收预算参数，`simulate` / `simulate_with` 仍是
「不限预算」。

**`advice` 的探测路径用的是同一个判据**（第十二轮审计，P2）。修复前
第四道守卫只挂在 `cmd_simulate` 上，而 `advice` 的每一次探测**就是**一次
`simulate`，一次也没走预算 —— 同一份模拟在两个入口得到相反的准入判定：

| 命令 | 修复前 | 修复后 |
|---|---|---|
| `simulate --days 22361 --new-per-day 1 --review-limit 1` | exit 2，16.4 s | 不变 |
| `advice --days 22361 --review-limit 1` | **exit 0，89.3 s** | exit 2，17.5 s |
| `advice --days 28000 --review-limit 1` | **exit 0，174.5 s** | exit 2，14.5 s |
| `advice --days 10954 --review-limit 1`（预算边界内侧） | exit 0 | exit 0，13.0 s |

（本机 native release；中止点与 `simulate` 逐字段相同：第 10959 天 /
`60008566` 条。判据与墙钟无关，秒数随机器变。）

`advice` 的成本形状又是另一种：它是**探测次数 × 单次模拟**，最坏

```
(review_limit + 2) × days² × review_limit      # --review-limit 0 时第 1、3 项用固定上界 500
```

`moon run cmd/recall -- advice` 在超界时 exit 2，报出两轴与乘积。

**阈值 `3e8`**（第十九轮 RC-19-4；修前是 `2.5e9`）。旧值的注释写着「上限档 ≈
三十秒量级」，实测**差一个数量级**——守卫允准的档位必须是自己实测能承受的档位，
否则守卫生效性等于零：

| 配置 | 工作单元 | 修前实测（上限 2.5e9） |
|---|---|---|
| `--days 90 --review-limit 200`（默认档） | `3.27e8` | 18.7 s |
| `--days 90 --review-limit 500` | `2.03e9` | **119.5 s** |
| `--days 248 --review-limit 200`（旧上限档） | `2.48e9` | **172.6 s** |
| `--days 99 --review-limit 500`（旧上限档） | `2.46e9` | **704 s（12 分钟）** |
| `--days 136 --review-limit 0` | `9.4e9` | 修前已 exit 2 |

降上限之后（同一台机器、native release、独立进程、`Stopwatch`）：

| 配置 | 工作单元 | 现在 |
|---|---|---|
| `--days 12 --review-limit 200` | `5.8e6` | 0.4 s |
| `--days 30 --review-limit 200`（拒绝消息里的「快速档」） | `1.8e7` | 1.5 s |
| `--days 60 --review-limit 200` | `1.45e8` | 6.2 s |
| `--days 86 --review-limit 200`（上限档，成本 99%） | `2.99e8` | 15.3 s |
| `--days 90 --review-limit 200`（默认档） | `3.27e8` | **exit 2** |
| `--days 99 --review-limit 500` | `2.46e9` | **exit 2（修前 704 s）** |

`3e8` 的取法：实测反推「约 1.5–16 s 的档位全部落在 `3e8` 以内」，上限档实测
15.3 s；同时它必须 ≥ `simulate_scan_limit()` 的 `2.5e8`，否则会出现「同规模
simulate 放行、advice 拒绝」的倒挂。代价是**默认档 `--days 90 --review-limit 200`
现在被拒**，拒绝消息会给出 `--days 86`（2.99e8，99% 上限）与 `--days 30`
（1/8 上限）两档，照改即可。

**差分验证**：上限只影响准入判定，不进入计算。同一批两边都放行的配置
（`--days 30/60/86 --review-limit 200`）在新旧上限二进制上的输出**逐字节相同**
（sha256 一致，`audit/2026-11-27/recall-evidence/perf/diff-result.txt`）。

边界值本身合法（`> 3e8` 才拒）。`--review-limit 0`（不限）的语义不变：
它只是让搜索上界 `hi` 取固定 500，与 `--review-limit 500` 同形，因此
`--days 90 --review-limit 0` 与 `--review-limit 500` 一样被拒（修前 211 ms，
一档能跑完的配置反而更快，属旧阈值的又一个反例）。库层
`load_advice` 不做这道**启动时**守卫——纯计算函数，成本决策留给调用方；
`load_advice_with_budget` 只做**运行时工作量**那一层，与 `simulate`
（`total_cards_error` / `simulate_scan_error` / `simulate_with_budget`）的分层
一一对应。

**为什么不是把 `advice` 改快**：`load_advice` 的成本是**算法内在**的
（最坏 `O(review_limit)` 次完整模拟，每个探测都是 `O(days × cards)`），
本节的成本形状就是它的定义。要提速只有两条路：降低单次模拟成本（`simulate`
自身）或换搜索方向（二分会把 45 报成 43，已在上文否掉）。所以本轮的处理是
**把守准入档位收紧到实测可承受范围**，而不是改算法——这也是为什么
`advice` 的锚点配置留在 `f(45)=422` 这类小规模上。

顺带一条实现事实（第十二轮）：每个返回分支以前会**把同一个配置再模拟一遍**
去填 `simulation` 字段。模拟器是确定性的，那第二遍与第一遍逐字段相同，
所以改成复用第一遍的结果——省掉**一次**完整模拟。注意这只是「一次」：
浅搜索（上界即达标，两次探测）时约占三成，深扫描（两百次探测）时可忽略
（上限 2.5e9 时实测 `--days 248 --review-limit 200` 仍要 172–256 s 量级；
上限降到 3e8 后，同一档被成本守卫直接拒绝）。输出逐字段不变
（`cmd/recall/advice_budget_wbtest.mbt` 锁定 `load_advice_with_budget` 与
`load_advice` 相同）。

**拒绝消息必须能执行**（R-7 同族）：除了报出两轴与乘积，末尾还给按当前
另一轴反算的可行值 —— 固定 `--review-limit` 时的 `--days` 上界
（`floor(sqrt(3e8 / ((hi+2)·hi)))`）与固定 `--days` 时的 `--review-limit`
上界（解 `h² + 2h <= 3e8 / days²`），两侧都代回判定确认通过才写进建议。
`--review-limit 0` 不反算这一侧（改成具体值会改掉「不限」语义），如实说
只能减 `--days`（实测：`advice --days 90 --review-limit 0` 现在 exit 2，
建议 `--days 34` —— 96% 上限；快速档 `--days 12`）。示例：

```
用法错误: advice 的总成本（探测次数 × 单次模拟 = 探测上界 × --days² × --review-limit）必须 <= 300000000，得到 202 × 5000² × 200 = 1010000000000（--days 5000，--review-limit 200）
  建议: 保持 --review-limit 200 时把 --days 降到 86 以内（上限档：成本约 99% 上限，是本守卫允准的最慢的一档）；或保持 --days 5000 时把 --review-limit 降到 2 以内（上限档：成本约 66% 上限）
  更快的一档: --days 30（--review-limit 不变）——成本约为上限的 1/8
```

**「建议值」不能是最慢的一档**（2026-11-17 审计，P3）：反算出来的上界值恰好
就是成本上限本身。照上一条建议改成「上限档」代回真跑，本机 native release 实测 **256.19 s**
（4 分 16 秒，2026-11-17 那台机器；2026-11-27 本机在上限 2.5e9 时实测
`--days 248` 172.6 s、`--days 99 --review-limit 500` 704 s）。第十九轮 RC-19-4
把上限降到 3e8 之后，上限档变成 `--days 86 --review-limit 200`，实测 **15.3 s**；
另给的**同一公式、上限压到 1/8** 的快速档变成 `--days 30`，实测 **1.5 s**。
两条快速档都先代回判定，只有真的更快（严格小于上限档）才写出来。

三个诚实分支：
- 连 0 张新卡都清不了存量 → 建议 0，summary 明说"存量太大"。
  （2026-11-15 审计注：模拟器从**空状态**起步，`new_per_day=0` 时没有
  卡进入模拟、最终积压恒为 0，而 `target_backlog < 0` 又在入口被
  RJ-A5 拒绝——`0 > target ≥ 0` 恒假，这条分支当前**不可达**，仅作
  防御性代码保留（「存量」这种输入还不存在）；
  `src/advice_deadbranch_test.mbt` 锁定 f(0)=0。）
- 上界内绰绰有余 → 直接返回 review_limit，提示可以调大上限
- 反直觉行为被自然捕捉：**学太快反而积压**（超过消化能力后，每天
  塞得越多、未复习的卡积得越多）——这正是必须用模拟而非公式的证据

### 5.2 Anki 可读格式导出 `src/anki.mbt`

产出 **Anki 文本导入格式**（TSV + 指令头），不是 .apkg 二进制——
.apkg 是 SQLite+zip 的私有打包，TSV 是 Anki 官方文档化的导入格式
（File > Import），不依赖 Anki 版本内部实现。

```moonbit
pub fn timestamp_to_iso8601(ts : Timestamp) -> String
pub fn export_anki_tsv(states : Array[CardState], scheduler_name : String) -> String
pub fn export_anki_from_log(log : ReviewLog, s : AnyScheduler) -> String
```

输出形如：

```
#separator:tab
#html:false
# scheduler: fsrs
#columns:card_id	stability	difficulty	reps	lapses	due	interval_days	phase
c1	9.468…	8.016…	24	6	2026-09-05 13:09:10	9	复习
```

要点：
- **每行一张卡的最终状态**（重放日志得到），卡片按 card_id 排序——
  两次导出可逐字节比较（有测试锁定）。
- `# scheduler:` 普通注释写调度器名：difficulty 列语义按调度器分派
  （FSRS=D(1..10) / SM-2=EF / Leitner=盒号），防止跨算法误读。
- `#columns` 使用真正的 Tab 分隔，与 `#separator:tab` 和数据行一致。
  调度器名不是 Anki 笔记类型，因此不输出 `notetype` 指令。
- 时间用 ISO8601（UTC），纯手写 civil_from_days 历法换算。
  **负时间戳必须 floor 除法**：例如 -1 秒对应 `1969-12-31 23:59:59`，
  应拆成第 -1 天及日内 86399 秒，不能向零截断成第 0 天及负余数。
  整天边界没有这种余数差异；`1900-02-28 00:00:00` 对应 -2203977600 秒。
- **年份宽度**（2026-10-27 修正描述）：不足 4 位补零到 4 位
  （`0001-01-01 00:00:00`），恰好 4 位原样，**超过 4 位原样输出、不截断**。
  `due` 可以合法地越过 9999 年：JSONL 允许的 `reviewed_at` 上限是
  253402300799（9999-12-31 23:59:59），加上 `max_interval_days()` = 36500
  天即 10099 年。**完整 Int64 域**（RJ-A1，2026-11-10 审计）：`Int64.MAX`
  对应 `292277026596-12-04 15:30:07`（旧文写 1587287 年，是 Int32 天数
  回绕的产物，已用 Python 版 Hinnant 复算证伪）。早年版本这里写着「年份
  补 4 位（Anki 的 CSV 解析器期待 4 位年）」，但实现从未执行过该约束；
  截断会把 10099 年写成 `0099`，比多一位数字更糟，故保留完整年份。
- CLI 用法：`recall replay --log FILE --scheduler fsrs --anki`
- 数据字段采用 Anki 的 CSV 引号规则：Tab、CR、LF、双引号必须保留在
  同一引用字段中，内部双引号翻倍；以 `#` 开头的卡片 ID 也引用以免变成注释。

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
pub fn retention_curve(
  log : ReviewLog,
  buckets : Int,
) -> Array[(Double, Double, Double)]
  // (桶下界天数, 桶上界天数, retention_rate)，桶为左闭右开 [lo, hi)；
  // 最后一桶闭区间 [lo, hi]，因为 elapsed == max 会被夹进末桶
```

`compute_stats` 与 `retention_curve` 按卡片分组并稳定按复习时间排序，
共用同一个间隔口径：优先采用日志明确记录的有限正 `elapsed_days`，否则仅由同卡
前驱回推；`NaN` / `+Infinity` 与 JSONL 写出口的 0 值同口径，内存事件与
序列化读回保持一致（`src/stats_nonfinite_explicit_interval_regression_test.mbt` 锁定）。
首条事件的正间隔可代表截断日志中的既有学习历史；首条零间隔
没有前驱，不计入间隔样本。同刻重复复习的零间隔有效，全部样本为零时曲线
返回一个 `[0, 0]` 的桶。**零间隔样本永远单独成桶 `[0, 0]`**（第二十二轮
RC-22-1）：`[0, 0]` 这一行只包含那些零间隔样本，其 `retention_rate` 也只由
它们决定；等宽桶里因此不存在「下界 0」的混淆——`(0, width)` 里的样本出现在
`[0, width)` 那一行，但那一行不再把 `iv == 0` 算进去。混合样本时返回顺序为
`[0, 0]` 在前、其余按桶下界升序。返回值同时给出每个桶的上下界，调用方打印标签时
必须按区间 `[lo, hi)` 呈现，不能只取上界写成 `< hi`（那会把边界样本
显示到高一档的标签下）。经验保持率受有限样本影响，不保证单调。

`overall_stats(rows)` 接收 `compute_stats` 生成的卡片统计。`mean_interval`
是有间隔样本的卡片均值的等权平均，判据为 `reviews > 1 || mean_interval > 0`：
首条显式正间隔会计入，首次零间隔无样本会排除，同刻重复复习的有效零样本会
计入分母。它不按间隔样本数量加权；没有有效样本时返回 0。手工构造
`CardStats` 时也应遵循上述约定。

当 `max_elapsed > 0` 但 `max_elapsed / buckets` 在 Double 中下溢为 0 时，
无法表示非退化的等宽桶；`retention_curve` 返回单个 `[0, max_elapsed]` 桶，
而不是把桶宽擅自改成 1 天。

**归桶成本与桶数无关**（2026-11-21 审计）：归桶用「除法起点 + 与标签同源的
`width * k` 乘法校正」直接定位，语义仍是「最大 k 使 `iv >= width*k`」
（RC-8 的桶沿反例不变，`src/stats_bucket_edge_regression_test.mbt` 583 组
穷举 + `src/curve_bucket_index_regression_test.mbt` 边界锁）。旧实现从
`bi = 0` 线性上扫，最坏 `samples × buckets`：1e5 事件日志上
`--buckets 10000` 比 `--buckets 100` 多约 **0.62 s**（1376 ms vs 760 ms，
native release）；现在是同量级（547–882 ms，主项为 JSONL 解析）。
实测见 `audit/2026-11-21/recall/evidence/curve-buckets-bench.log`。

**均值不溢出不变量**（2026-11-17 审计）：`elapsed_days` 只被要求**有限**
（§2），所以 `1e308` 这种合法输入可以合法地进入统计。`compute_stats` /
`overall_stats` / `replay` 的均值一律用**增量式** `mean += (x − mean)/n`
（而不是「求和后相除」），因此

```
CardStats.mean_interval <= CardStats.max_interval      （任意合法日志恒成立）
OverallStats.mean_interval <= 各卡 mean_interval 的最大值
```

修复前 `1e308 + 1e308` 越过 Double 上界变成 `+Inf`，于是 `stats` 打出
`均间隔 Infinity / 最大间隔 1e+308`（均值大于最大值），`replay --json` 的
`interval_error_days` 直接产出 `Infinity`（不是 JSON）。

**`replay` 的两侧都只收有限值**（2026-11-21 审计）：实际间隔取「有限且
`> 0`」的 `elapsed_days`，否则按同卡前驱时间戳回推——与
`stats.review_interval`、`ReviewEvent::new` 写出口的 `0` 同一判据；调度侧
`state.interval_days` 为 `±Infinity` / `NaN`（只可能来自手工构造的
`CardState`）时不产生偏差样本。因此内存重放与 `to_jsonl → from_jsonl`
再重放**逐字段相同**，`+Infinity` 也不会把均值拖成 `Infinity` / `NaN`。

## 7. CLI `cmd/recall/main.mbt`

```
recall replay   --log <file.jsonl> --scheduler sm2|fsrs|leitner [--json]
recall compare  --log <file.jsonl> --a sm2 --b fsrs
recall simulate --scheduler fsrs --days 90 --new-per-day 20 --review-limit 200 --policy realistic [--retention 0.9] [--seed N]
recall advice   --scheduler fsrs --days 90 --review-limit 200 --target-backlog 0 [--policy realistic] [--retention 0.9] [--seed N]
recall stats    --log <file.jsonl>
recall curve    --log <file.jsonl> --buckets 10
```

退出码：0 成功，1 数据错误，2 用法错误。

**输出流分道（第十七轮审计 F1）**：stdout **只放数据**——`--json` 的 JSON、
`--anki` 的 TSV、各命令的表格与摘要、`--help` 的用法文本；**诊断一律走
stderr**——用法错误、数据错误、量级守卫的拒绝理由、预算中止、`⚠` 解读提示、
「提示: …」这类夹取告知。

```powershell
# 修前（错）：诊断写在 stdout，坏日志让 out.json 变成一行中文
recall replay --log bad.jsonl --json > out.json   # out.json = "数据错误: 第 2 行…"
# 修后（对）：out.json 一个字节都没有，诊断在 stderr，退出码 1
```

入口是 `main.mbt` 的 `emit`（stdout）/ `diag`（stderr）两个函数，接收端用
`Ref` 暴露（`stdout_sink` / `stderr_sink`），白盒测试替换它们来断言分流，
见 `cmd/recall/cli_stream_split_wbtest.mbt`。

**控制台表格净化（第十七轮审计 F2）**：卡号来自日志，是**不可信数据**。
`stats` / `replay` / `compare` 的表格单元格一律过 `cell_text`：`\n` `\r` `\t`
转义成 `\n` `\r` `\t` 字面量，其余 C0/C1 控制字符（`< 0x20`、`0x7F..0x9F`，
含 `ESC`）写成 `\uXXXX`，列宽按转义后的长度算。于是「一张卡一行」与列对齐
都是可依赖的，ANSI 序列也不会改写终端。三个输出出口各有守卫：`--json` 走
`Json::string`、`--anki` 走 CSV 引号规则、控制台表格走 `cell_text`
（`cmd/recall/table_cell_escape_wbtest.mbt` 锁定）。


`--json` / `--anki` 是布尔参数，**显式 `false` 生效**：`--json=false` / `--json=0`
关掉 JSON（打印表格），`--json` / `--json=` / `--json=true` 开启（2026-11-17 审计）。

`--days 0` 在两个子命令上**有意不同**：`simulate --days 0` 是良定义的空结果
（库层 `simulate_test.mbt` 也锁了 `days=0 ⇒ 空结果`，`args_wbtest.mbt` 锁了
CLI 侧合法），而 `advice --days 0` 必须拒绝——`days` 出现在它的成本公式分母
（`(hi+2)·days²·hi`）上，0 会让守卫失去意义。两处口径的差异写进了 usage 文案。

`--json` 输出（`replay`）里的**每个浮点字段**都走 `fmt_json_number`：非有限值
写成 `null`（JSON 没有 `Infinity` / `NaN` 字面量），有限值照定点/指数输出。
因此「输出可以被任何 JSON 解析器读」是一条可断言的契约
（`cmd/recall/json_number_guard_wbtest.mbt` 锁定）。

## 8. 测试要求

- SM-2 表格测试：给定序列，逐次间隔必须匹配手算值
- FSRS：`R(t=S, S) ≈ 0.9`（浮点容差 1e-6）
  ——第十七轮审计把这条**收紧成逐位相等**：`forgetting_curve(s, s) == 0.9`
  对 `s ∈ {5e-324, 1e-300, …, 1.7e308}` 全部成立（`src/fsrs_curve_exact_test.mbt`）。
  修前 `FACTOR · t / S` 是「先乘后除」，`t` 为次正规数时 `FACTOR · t` 下溢成 0，
  R 变 1.0；改成 `FACTOR · (t / S)` 后 `t / S = 1` 精确。常态量级只差 ≤1 ulp。
  另记一笔边界口径：`I(S, 0.9)` 在**取整前**等于 `S`，但 `S` 恰好是 `k + 0.5`
  时 `pow(0.9, -2)` 与 `1 + 19/81` 差 1 ulp，取整会落到 `k` 而不是 `k + 1`
  （与 py-fsrs 同一个表达式、同一个结果，属已声明的浮点口径，不是缺陷）。
- 单调性属性测试：
  - 同一卡片，Good 的间隔 ≥ Hard 的间隔
  - 间隔随 reps 单调不减
  - EF 永不低于 1.3
  - retention_curve 不受跨卡交错与文件行序影响，保持率在 [0,1]
- 重放确定性：同一日志跑两次结果完全一致
- **重放确定性的边界：同刻多条事件与文件行序**（第二十轮 RC-20-3，2026-11-28）

  「跑两次一致」是**弱**确定性。实测它**不**蕴含「同内容不同行序一致」：把同一张卡、
  同一时刻的两条不同事件在文件里换个顺序，最终状态会变。

  ```
  [A(Good@t0), B(Again@t0+D), C(Easy@t0+D)]   ->  final interval 2.0
  [A(Good@t0), C(Easy@t0+D), B(Again@t0+D)]   ->  final interval 6.0
  ```

  两层原因：①`ReviewLog::by_card` 的排序用「稳定 + 相等返回 -1」，比较器在相等时
  `<` 与 `>` 同时为真（自相矛盾），结果依赖底层排序在相等元素上的处理；②缺
  `elapsed_days` 的事件，间隔由**上一条**事件回推，同刻两条谁先谁后就决定「上一条」
  是谁。

  影响面：CalDAV / Anki 导出这类来源确有「同一秒两条复习」（批量拖动、批量导入）。
  同一份文件反复跑仍逐字节一致（弱确定性成立），但**摘要值必须连同规范化后的行序
  一起比对**，否则同一个数据集的两个副本可能给出不同摘要。

  不修语义的理由：同刻事件的业务先后在日志里没有任何字段可依据，实现凭什么替用户
  排序都是编造。本轮只把边界写成可执行断言（`src/replay_tie_order_boundary_test.mbt`，
  用 `i1 != i2` 钉住当前行为）并记录在此；哪天改成「按内容全序」，那条断言会红，
  提醒同步本节与 `src/replay.mbt` 的注释。

  **用户可见面**（2026-11-29 追加，Lead 裁决）：只写进本文档不够——`replay --json`
  的使用者读的是 stdout 与 stderr，不是 API.md。所以同刻事件现在同时发到三处：

  | 出口 | 内容 |
  |---|---|
  | stderr | 每张卡一条诊断：`警告: 卡片 <id> 有 <N> 条同刻事件——其先后按文件行序决定，换序可能改变摘要（--json 的 same_timestamp_groups 会标出这类卡片）`，按 card_id 升序 |
  | `--json` | 追加 `"same_timestamp_groups":N`（N = 有同刻组的**卡片数**；为 0 时**不写这个键**，保持原 JSON 形状） |
  | 人读表格 / `--anki` | 不变（stdout 数据段一个字节都不动） |

  判据：`ReplayResult.same_timestamp_groups`（日志属性，与调度器无关，三个调度器
  给出同一个数）。实测（`k` 卡第二条与第三条同为 `t0+86400`）：

  ```
  $ recall replay --log tied.jsonl --scheduler fsrs --json
  {"scheduler":"fsrs",…,"late_review_ratio":0.0000,"same_timestamp_groups":1,"final_intervals":{"k":6.00}}
  stderr: 警告: 卡片 k 有 2 条同刻事件——…

  $ recall replay --log untied.jsonl --scheduler fsrs --json      # 无同刻
  {"scheduler":"fsrs",…,"late_review_ratio":0.0000,"final_intervals":{"k":2.00}}
  stderr: (空)
  ```

  无同刻事件的输出与第十九轮**逐字节相同**（回归用例
  `cmd/recall/same_ts_warning_emit_wbtest.mbt` 与库层
  `src/replay_same_timestamp_warning_test.mbt` 共同锁定）。

- JSONL 往返
- 模拟：new_per_day=0 时 backlog 单调不增
