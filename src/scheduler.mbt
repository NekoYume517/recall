// recall — 调度器接口
//
// 合同：API.md 第 3 节 + CONTRACT-FIX.md（MoonBit 没有 trait object）。
//
// 本文件是**全项目的中枢**：replay / simulate / stats / CLI 都只通过
// `Scheduler` 这个 trait（泛型约束）或 `AnyScheduler`（运行期枚举分发）
// 来调用调度算法，不认识任何具体实现。
//
// ⚠️ 协作约定（给 recall-engine）：
//   - `Fsrs` 结构体的**定义在本文件末尾**（最小 stub，只有 API.md 声明的
//     `w`、`desired_retention` 两个字段 + `new()`）。
//   - recall-engine 只需在 `src/fsrs.mbt` 里写 `impl Scheduler for Fsrs`、
//     以及自己的内部公式函数；**不要再定义一次 `struct Fsrs`**，
//     否则同包内重复定义会编译失败。
//
// ⚠️ 泛型写法（CONTRACT-FIX 修正 1）：`fn[T : Scheduler] f(...)`，
//   `[T]` 在函数名**前面**。

///|
/// 调度器统一接口。所有算法（SM-2 / FSRS / Leitner）都实现它。
///
/// 设计原则：
/// - 状态是**值**，`review` 返回新状态而不修改入参（纯函数，可重放）。
/// - 时间用 `Timestamp`（Int64 秒），算法内部再换成天数，避免浮点漂移。
/// - 调度器自身只持有**超参数**（EF 初值、权重、盒表），
///   每张卡的学习状态全部在 `CardState` 里，因此一个实例可以服务整个日志。
pub trait Scheduler {
  ///|
  /// 调度器名字，用于 CLI、报告和跨算法对比表。
  /// 约定小写短名：`"sm2"` / `"fsrs"` / `"leitner"`。
  fn name(Self) -> String

  ///|
  /// 新卡初始化。
  ///
  /// 语义：
  /// - 返回一张**从未复习**的卡：`reps == 0`、`lapses == 0`、`phase == New`。
  /// - `due` 应等于 `now`（新卡立即可学），`last_review` 也取 `now`，
  ///   这样 `days_between(last_review, now) == 0`，第一次复习的 elapsed 为 0。
  /// - 允许把算法自己的初值写进 `CardState` 的通用字段
  ///   （例如 SM-2 把初始 EF 写进 `difficulty`，Leitner 把盒号写成 1）。
  ///   这样重放时无需再问调度器"这张卡的初始参数是多少"。
  fn init(Self, card_id : String, now : Timestamp) -> CardState

  ///|
  /// 应用一次复习，返回**新**状态（不得就地修改入参）。
  ///
  /// 必须做对的事：
  /// - 用 `now` 填充 `last_review`，用新间隔算出 `due`。
  /// - 维护 `reps`（成功次数）、`lapses`（遗忘次数）、`interval_days`。
  /// - 更新算法自身的记忆参数（FSRS 的 S/D、SM-2 的 EF、Leitner 的盒号）。
  /// - `phase` 要与间隔一致：短间隔是 Learning，长间隔是 Review。
  fn review(Self, state : CardState, grade : Grade, now : Timestamp) -> CardState

  ///|
  /// 当前可提取性 R(now)，即"此刻还记得的概率"。返回值必须在 [0, 1]。
  ///
  /// ⚠️ **各算法含义不同，不要假设它是遗忘曲线**：
  /// - `Fsrs`：真正的遗忘曲线 R(t,S) = (1 + 19/81 · t/S)^(-0.5)，
  ///   其中 t 是距上次复习的天数、S 是 state.stability。R(t=S) = 0.9。
  ///   这是唯一"可解释、可校准"的实现。
  /// - `Sm2`：**近似值**。SM-2 原文没有遗忘曲线，只有间隔；
  ///   这里用指数衰减 0.9^(t/S) 借 `interval_days` 当 S，
  ///   只为让 replay/stats 能画出可比曲线，不能当作 SM-2 的官方参数。
  /// - `Leitner`：**基线约定值**。盒模型只表达"到期/未到期"，
  ///   这里用分段线性：到期前恒为 1.0，逾期后按 (1 - 逾期比例) 线性衰减到 0。
  ///
  /// 因此跨算法比较 retrievability 时，只有 FSRS 的数值有物理意义。
  fn retrievability(Self, state : CardState, now : Timestamp) -> Double

  ///|
  /// 目标保持率（FSRS 的 desired_retention，默认 0.9）。
  ///
  /// - `Fsrs`：调用方配置的值，间隔按它反解。
  /// - `Sm2`：固定 0.9（与 retrievability 的校准点一致）。
  /// - `Leitner`：固定 1.0（盒模型只要求"到期就复习"）。
  fn desired_retention(Self) -> Double
}

///|
/// FSRS-5 的状态容器。
///
/// **这是最小 stub（仅类型 + 构造器）**：字段严格按 API.md 第 3.2 节，
/// 公式与 `impl Scheduler for Fsrs` 由 `src/fsrs.mbt`（recall-engine）提供。
/// 放在这里的唯一原因是 `AnyScheduler` 需要引用这个类型；
/// 等 fsrs.mbt 交付后，本段**不需要删**——只要 fsrs.mbt 不再重复
/// 定义 `struct Fsrs`，两边就能共存。
pub(all) struct Fsrs {
  w : Array[Double] // 21 个权重，默认用 FSRS-5 官方值
  desired_retention : Double // 默认 0.9
} derive(Debug)

///|
/// FSRS-5 官方默认权重。
///
/// FSRS-5 公式用到 w0..w18（19 个）；API.md 声明数组长度为 21，
/// 因此这里给满 21 个，w19/w20 是官方仓库里的扩展位（当前公式不使用），
/// 保留它们是避免 recall-engine 用 `w[19]`/`w[20]` 时越界。
pub fn fsrs_default_w() -> Array[Double] {
  [
    0.40255, 1.18385, 3.173, 15.69105, 7.1949, 0.5345, 1.4604, 0.0046, 1.54575, 0.1192,
    1.01925, 1.9395, 0.11, 0.29605, 2.2698, 0.2315, 2.9898, 0.51655, 0.6621, 0.0,
    0.0,
  ]
}

///|
/// 默认 FSRS 实例：官方权重 + 90% 目标保持率。
pub fn Fsrs::new() -> Fsrs {
  { w: fsrs_default_w(), desired_retention: 0.9, }
}

///|
/// 带自定义权重的 FSRS 实例。权重不足 19 个时退回官方默认值——
/// 半截权重会让公式算出 NaN，静默截断比直接退回更危险。
pub fn Fsrs::with_params(w : Array[Double]) -> Fsrs {
  if w.length() < 19 {
    Fsrs::new()
  } else {
    { w, desired_retention: 0.9, }
  }
}

///|
/// 只改目标保持率的构造器，间隔会按它反解。
pub fn Fsrs::with_retention(retention : Double) -> Fsrs {
  let r = if retention <= 0.0 || retention >= 1.0 { 0.9 } else { retention }
  { w: fsrs_default_w(), desired_retention: r, }
}

///|
/// `Scheduler` 的存在类型包装（CONTRACT-FIX 方案 B）。
///
/// MoonBit 没有 trait object，CLI 又要按名字选算法，所以用枚举把三种
/// 具体类型装起来；`AnyScheduler` 自己也 `impl Scheduler`，
/// 因此任何 `[T : Scheduler]` 泛型函数都能直接吃它，无需另写一份。
pub(all) enum AnyScheduler {
  Sm2(Sm2)
  Fsrs(Fsrs)
  Leitner(Leitner)
} derive(Debug)

///|
/// 按名字构造调度器。未知名字退回 Leitner（最保守的基线），不抛错——
/// CLI 用 `scheduler_name_valid` 先校验，再决定是否以 exit code 2 退出。
pub fn AnyScheduler::by_name(name : String) -> AnyScheduler {
  match name {
    "sm2" => Sm2(Sm2::new())
    "fsrs" => Fsrs(Fsrs::new())
    _ => Leitner(Leitner::new())
  }
}

///|
/// 按名字构造调度器，并把**目标保持率**透传给支持它的实现。
///
/// 这修复了一个真实缺陷（R1）：`--retention 0.70` 曾经被 CLI 读进
/// `SimConfig.desired_retention` 后**无人读取**——调度器由 `by_name`
/// 固定 0.9 构造，CLI 还把这个值打印成「目标保持率 0.70」，承诺了
/// 一个不存在的旋钮。两次不同的 retention 跑出逐字节相同的输出。
///
/// 语义按实现分派：
///   - **FSRS**：`desired_retention` 是算法的一等参数（间隔由它反解），
///     直接用 `Fsrs::with_retention(r)`。
///   - **SM-2 / Leitner**：没有保持率参数——这是算法的固有局限，
///     不是缺陷。原样返回默认构造；CLI 会提示该值对此调度器无效。
pub fn AnyScheduler::by_name_with_retention(
  name : String,
  retention : Double,
) -> AnyScheduler {
  match name {
    "sm2" => Sm2(Sm2::new())
    "fsrs" => Fsrs(Fsrs::with_retention(retention))
    _ => Leitner(Leitner::new())
  }
}

///|
/// 名字是否是受支持的调度器名（供 CLI 做用法校验）。
pub fn scheduler_name_valid(name : String) -> Bool {
  match name {
    "sm2" | "fsrs" | "leitner" => true
    _ => false
  }
}

///|
/// 全部受支持的调度器名，供 `--help` 与错误提示复用。
pub fn scheduler_names() -> Array[String] {
  ["sm2", "fsrs", "leitner"]
}

// ─────────────────────────────────────────────────────────────────
// FSRS 的 `impl Scheduler` 由 `src/fsrs.mbt` 提供（recall-engine 交付）。
//
// 原先这里的占位实现已按交接约定删除：同一包内不能有两份
// `impl Scheduler for Fsrs`。`struct Fsrs` / `Fsrs::new` /
// `Fsrs::with_params` / `Fsrs::with_retention` / `fsrs_default_w`
// 仍留在本文件，供 `AnyScheduler` 与下游使用。
// ─────────────────────────────────────────────────────────────────

///|
/// 运行期名字。
pub impl Scheduler for AnyScheduler with fn name(self) {
  match self {
    Sm2(s) => Scheduler::name(s)
    Fsrs(s) => Scheduler::name(s)
    Leitner(s) => Scheduler::name(s)
  }
}

///|
/// 运行期初始化。
pub impl Scheduler for AnyScheduler with fn init(self, card_id, now) {
  match self {
    Sm2(s) => Scheduler::init(s, card_id, now)
    Fsrs(s) => Scheduler::init(s, card_id, now)
    Leitner(s) => Scheduler::init(s, card_id, now)
  }
}

///|
/// 运行期复习。
pub impl Scheduler for AnyScheduler with fn review(self, state, grade, now) {
  match self {
    Sm2(s) => Scheduler::review(s, state, grade, now)
    Fsrs(s) => Scheduler::review(s, state, grade, now)
    Leitner(s) => Scheduler::review(s, state, grade, now)
  }
}

///|
/// 运行期可提取性。
pub impl Scheduler for AnyScheduler with fn retrievability(self, state, now) {
  match self {
    Sm2(s) => Scheduler::retrievability(s, state, now)
    Fsrs(s) => Scheduler::retrievability(s, state, now)
    Leitner(s) => Scheduler::retrievability(s, state, now)
  }
}

///|
/// 运行期目标保持率。
pub impl Scheduler for AnyScheduler with fn desired_retention(self) {
  match self {
    Sm2(s) => Scheduler::desired_retention(s)
    Fsrs(s) => Scheduler::desired_retention(s)
    Leitner(s) => Scheduler::desired_retention(s)
  }
}

///|
/// 通用「复习一次并记录时间」包装：等价于 `review`，但读起来更顺，
/// 也方便未来在这里加统一的日志/断言。
pub fn[T : Scheduler] apply_review(
  scheduler : T,
  state : CardState,
  grade : Grade,
  now : Timestamp,
) -> CardState {
  Scheduler::review(scheduler, state, grade, now)
}

///|
/// 把可提取性夹到 [0, 1]。所有实现都走它，保证契约里的值域。
pub fn clamp_retrievability(r : Double) -> Double {
  if r.is_nan() {
    0.0
  } else if r < 0.0 {
    0.0
  } else if r > 1.0 {
    1.0
  } else {
    r
  }
}
