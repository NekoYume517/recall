// recall — SuperMemo 2（1987）
//
// 合同：API.md 第 3.1 节（已由 lead 修正为权威版本）。
//
// ── 三个刻度，千万别混 ────────────────────────────────────────────
// 1. `Grade::to_int`（展示用）：Again=0, Hard=2, Good=3, Easy=5
// 2. SM-2 的 `q`（公式用）：      Again=2, Hard=3, Good=4, Easy=5
// 3. 答错判定：`q < 3`，也就是**只有 Again 算答错**
//    （Hard 虽然"不通过"（to_int=2 < 3），但在 SM-2 里算答对）
//
// ── 顺序 ─────────────────────────────────────────────────────────
// 先用**上一次复习遗留的 EF** 算间隔，再用本次评分更新 EF。
// 这是 SM-2 原文顺序，反过来会让间隔整体偏大。

///|
/// 经典 SuperMemo 2 的超参数容器。
///
/// 三个字段是**默认值/初值**，不是当前卡的状态：真实状态在 `CardState`
/// 里（EF 存 `difficulty`、间隔存 `interval_days`、repetitions 存 `reps`）。
/// 之所以仍然保留这三个字段：API.md 要求，且便于构造"非默认初值"的实例做实验。
pub(all) struct Sm2 {
  ease_factor : Double // 默认 2.5，下限 1.3
  interval_days : Double
  repetitions : Int32
} derive(Debug)

///|
/// EF 下限。低于它间隔增长会退化成 1.3 倍，SM-2 原文定为 1.3。
pub fn sm2_min_ease() -> Double {
  1.3
}

///|
/// EF 初值。新卡从 2.5 开始。
pub fn sm2_default_ease() -> Double {
  2.5
}

///|
/// 默认 SM-2：EF=2.5，无间隔，无复习次数。
pub fn Sm2::new() -> Sm2 {
  { ease_factor: 2.5, interval_days: 0.0, repetitions: 0, }
}

///|
/// 指定 EF 初值的 SM-2（低于 1.3 会被夹到 1.3）。
pub fn Sm2::with_ease(ease : Double) -> Sm2 {
  let ef = if ease < sm2_min_ease() { sm2_min_ease() } else { ease }
  { ease_factor: ef, interval_days: 0.0, repetitions: 0, }
}

///|
/// 评分 → SM-2 的 `q`（0..5 量表）。
///
/// **这是唯一权威映射，不要在别处再造一个**：
/// Again→2, Hard→3, Good→4, Easy→5。
/// （注意与 `Grade::to_int` 的 0/2/3/5 完全不同。）
pub fn sm2_quality(grade : Grade) -> Int32 {
  match grade {
    Again => 2
    Hard => 3
    Good => 4
    Easy => 5
  }
}

///|
/// 该评分是否算「答对」。判据是 `q >= 3`，即只有 Again 算答错。
pub fn sm2_is_correct(grade : Grade) -> Bool {
  sm2_quality(grade) >= 3
}

///|
/// 单次 EF 增量：`0.1 - (5-q) * (0.08 + (5-q) * 0.02)`。
///
/// 典型值：q=5 → +0.10，q=4 → 0.00，q=3 → -0.14，q=2 → -0.32。
pub fn sm2_ease_delta(q : Int32) -> Double {
  let diff = (5 - q).to_double()
  0.1 - diff * (0.08 + diff * 0.02)
}

///|
/// 按 SM-2 规则更新 EF（带 1.3 下限）。纯函数，方便单测。
pub fn sm2_next_ease(ease : Double, grade : Grade) -> Double {
  let next = ease + sm2_ease_delta(sm2_quality(grade))
  if next < sm2_min_ease() {
    sm2_min_ease()
  } else {
    next
  }
}

///|
/// 按 SM-2 规则算下一次间隔（不含 EF 更新）。
///
/// `repetitions` 传**本次复习之前**的值：
/// - 答错 → 1.0（并会在调用方把 repetitions 归零）
/// - 第 1 次成功 → 1.0
/// - 第 2 次成功 → 6.0
/// - 之后 → `round(prev_interval * ease)`，ease 用**更新前**的 EF
pub fn sm2_next_interval(
  prev_interval : Double,
  ease : Double,
  repetitions : Int32,
  grade : Grade,
) -> Double {
  if !sm2_is_correct(grade) {
    return 1.0
  }
  let n = repetitions + 1
  if n == 1 {
    1.0
  } else if n == 2 {
    6.0
  } else {
    @math.round(prev_interval * ease)
  }
}

///|
/// 名字。
pub impl Scheduler for Sm2 with fn name(self) {
  "sm2"
}

///|
/// 新卡：EF 初值写进 `difficulty`，其余归零、`due = now`。
pub impl Scheduler for Sm2 with fn init(self, card_id, now) {
  {
    card_id,
    stability: 0.0,
    difficulty: self.ease_factor, // SM-2 借用 difficulty 保存 EF
    reps: 0,
    lapses: 0,
    last_review: now,
    due: now,
    interval_days: 0.0,
    phase: New,
  }
}

///|
/// 应用一次复习。
///
/// 状态映射（CardState ↔ SM-2）：
/// - `difficulty`     ↔ ease_factor（EF），下限 1.3
/// - `reps`           ↔ repetitions（成功复习次数）
/// - `interval_days`  ↔ 当前间隔
/// - `stability`      ↔ 间隔的镜像（给 stats/曲线画图用，不参与决策）
pub impl Scheduler for Sm2 with fn review(self, state, grade, now) {
  let prev_ease = if state.difficulty < sm2_min_ease() {
    self.ease_factor
  } else {
    state.difficulty
  }
  let correct = sm2_is_correct(grade)
  // 1) 先用「上一次的 EF」和「上一次的 repetitions」算间隔
  let interval = sm2_next_interval(
    state.interval_days,
    prev_ease,
    state.reps,
    grade,
  )
  // 2) 再更新 EF（每次复习都做，答错也做）
  let ease = sm2_next_ease(prev_ease, grade)
  // 3) 计数与阶段
  let reps = if correct { state.reps + 1 } else { 0 }
  let lapses = if correct { state.lapses } else { state.lapses + 1 }
  let phase = if !correct {
    Relearning
  } else if reps >= 3 {
    Review
  } else {
    Learning
  }
  {
    card_id: state.card_id,
    stability: interval, // 镜像，仅供报表
    difficulty: ease,
    reps,
    lapses,
    last_review: now,
    due: add_days(now, interval),
    interval_days: interval,
    phase,
  }
}

///|
/// 可提取性——**近似值，不是 SM-2 的官方量**。
///
/// SM-2 只有间隔，没有遗忘曲线。这里借用 SM-2 自己"间隔即 90% 保持点"
/// 的隐含假设（Anki 的默认行为），用指数衰减：
///
///   R = 0.9 ^ (t / S)，S 取当前 `interval_days`（没有间隔时用 1 天兜底）
///
/// 因此 R(t=S) = 0.9，与 FSRS 的校准点一致，两条曲线可以直接叠图比较。
/// 但它是**约定**而非推导：SM-2 的 EF 并不满足真实遗忘曲线。
pub impl Scheduler for Sm2 with fn retrievability(self, state, now) {
  let t = days_between(state.last_review, now)
  if t <= 0.0 {
    return 1.0
  }
  let s = if state.interval_days > 0.0 { state.interval_days } else { 1.0 }
  clamp_retrievability(@math.pow(0.9, t / s))
}

///|
/// 目标保持率。SM-2 没有这个概念，固定返回 0.9（即 retrievability 的校准点）。
pub impl Scheduler for Sm2 with fn desired_retention(self) {
  0.9
}
