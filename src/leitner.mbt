// recall — Leitner 盒子模型
//
// 合同：API.md 第 3.3 节。
//
// 规则（比 SM-2/FSRS 简单得多，作为对照基线）：
//   - 答对 → 进下一盒（到顶后留在最后一盒）
//   - 答错 → 回第 1 盒
//   - 间隔取「当前盒」的间隔天数
//
// 「答对/答错」用全项目统一的 `is_recalled(g) = (g != Again)`：
//   只有 Again 记遗忘，Hard 仍进下一盒。
//   这样 `compare --a sm2 --b leitner` 才是在同一「答对」定义下比较。
//
// 注意：这里没有 EF、没有遗忘曲线、也没有难度。它存在的价值是给
// replay/stats 提供一个"最笨的调度器"下界，用来看别的算法到底省了多少。

///|
/// 默认盒数。
pub fn leitner_default_boxes() -> Int32 {
  5
}

///|
/// 默认每盒间隔天数：盒 1..5 → 1, 2, 4, 8, 16 天。
pub fn leitner_default_intervals() -> Array[Double] {
  [1.0, 2.0, 4.0, 8.0, 16.0]
}

///|
/// Leitner 盒子调度器。
///
/// `boxes` 与 `intervals` 理论上应当等长；构造器保证这一点，
/// 读取间隔时再用 `min(box, intervals.length())` 兜底，避免越界。
pub(all) struct Leitner {
  boxes : Int32 // 默认 5
  intervals : Array[Double] // 每盒间隔天数，默认 [1, 2, 4, 8, 16]
} derive(Debug)

///|
/// 默认 Leitner：5 盒，间隔 1/2/4/8/16 天。
pub fn Leitner::new() -> Leitner {
  { boxes: 5, intervals: leitner_default_intervals(), }
}

///|
/// 自定义盒数。`intervals` 按 2 的幂生成（1, 2, 4, 8, ...），
/// 与默认表同构，方便做"更多盒子"的对比实验。
pub fn Leitner::with_boxes(boxes : Int32) -> Leitner {
  let n = if boxes < 1 { 1 } else if boxes > 20 { 20 } else { boxes }
  let table : Array[Double] = []
  for i in 0..<n {
    table.push(@math.pow(2.0, i.to_double()))
  }
  { boxes: n, intervals: table, }
}

///|
/// 盒号（1-based）→ 间隔天数。
/// 越界的盒号夹到 [1, boxes]，再按 `intervals` 长度兜底。
fn Leitner::interval_of(self : Leitner, box : Int32) -> Double {
  let last = if self.intervals.length() == 0 {
    return 1.0
  } else {
    self.intervals.length()
  }
  let b = if box < 1 { 1 } else if box > last { last } else { box }
  self.intervals[b - 1]
}

///|
/// 从状态里读出盒号。Leitner 借用 `CardState.difficulty` 存盒号（1-based），
/// 因此新卡（difficulty = 0）读出来就是盒 1。
fn leitner_box_of(state : CardState) -> Int32 {
  let b = state.difficulty.to_int()
  if b < 1 {
    1
  } else {
    b
  }
}

///|
/// 名字。
pub impl Scheduler for Leitner with fn name(self) {
  "leitner"
}

///|
/// 新卡：盒 1，`due = now`，`difficulty` 存盒号 1。
pub impl Scheduler for Leitner with fn init(self, card_id, now) {
  let interval = self.interval_of(1)
  {
    card_id,
    stability: interval,
    difficulty: 1.0, // 盒号 1
    reps: 0,
    lapses: 0,
    last_review: now,
    due: now,
    interval_days: interval,
    phase: New,
  }
}

///|
/// 应用一次复习：答对进一盒、答错回盒 1。
///
/// 与 SM-2 / stats 一致：只有 Again 记为遗忘，Hard 仍进下一盒。
/// 这是全项目统一的 `is_recalled` 判定。
///
/// 为什么 Leitner 也不能用更严格的「Hard 算错」：Leitner 是对照基线，
/// 它存在的意义就是和 SM-2 / FSRS 在**同一份日志**上比较复习量。
/// 如果它对 Hard 的解读与别人不同，`compare --a sm2 --b leitner`
/// 就会混入两种「答对」定义，数字失去可比性。
pub impl Scheduler for Leitner with fn review(self, state, grade, now) {
  let prev_box = leitner_box_of(state)
  let pass = is_recalled(grade)
  let box = if !pass {
    1
  } else if prev_box >= self.boxes {
    self.boxes
  } else {
    prev_box + 1
  }
  let interval = self.interval_of(box)
  let reps = if pass { state.reps + 1 } else { state.reps }
  let lapses = if pass { state.lapses } else { state.lapses + 1 }
  let phase = if !pass {
    if state.reps == 0 {
      Learning
    } else {
      Relearning
    }
  } else if box >= 3 {
    Review
  } else {
    Learning
  }
  {
    card_id: state.card_id,
    stability: interval,
    difficulty: box.to_double(),
    reps,
    lapses,
    last_review: now,
    due: add_days(now, interval),
    interval_days: interval,
    phase,
  }
}

///|
/// 可提取性——**基线约定值，不是概率模型**。
///
/// 盒模型只表达"到期/未到期"，没有遗忘曲线。这里给出分段线性约定：
///
///   未到期：R = 1.0（盒模型假定到期前一定记得）
///   逾期：  R = max(0, 1 - 逾期天数 / 当前间隔)
///
/// 于是到期当天 R=1，逾期一个完整间隔后 R=0。单调递减、值域 [0,1]，
/// 足以让 retention 曲线画出形状，但不能用来和 FSRS 数值对比。
pub impl Scheduler for Leitner with fn retrievability(self, state, now) {
  let overdue = days_between(state.due, now)
  if overdue <= 0.0 {
    return 1.0
  }
  let span = if state.interval_days > 0.0 { state.interval_days } else { 1.0 }
  clamp_retrievability(1.0 - overdue / span)
}

///|
/// 目标保持率。盒模型固定 1.0（到期就必须复习，没有"允许忘记"的余地）。
pub impl Scheduler for Leitner with fn desired_retention(self) {
  1.0
}
