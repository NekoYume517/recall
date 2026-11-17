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
#derive(Debug)
pub(all) struct Leitner {
  boxes : Int32 // 默认 5
  intervals : Array[Double] // 每盒间隔天数，默认 [1, 2, 4, 8, 16]
}

///|
/// 默认 Leitner：5 盒，间隔 1/2/4/8/16 天。
pub fn Leitner::new() -> Leitner {
  { boxes: 5, intervals: leitner_default_intervals(), }
}

///|
/// 自定义盒数。`intervals` 按 2 的幂生成（1, 2, 4, 8, ...），
/// 与默认表同构，方便做"更多盒子"的对比实验。
/// 带校验的自定义盒表（第十二轮审计，P3）。
///
/// `Leitner` 是 `pub(all)`，两个字段可以被直接构造，所以「不同步」只能在
/// **入口**显式拒绝：这里要求 `intervals.length() == boxes`——盒数只有一个
/// 定义，不接受两套。输入数组会被复制（与 `Fsrs::with_params` 同一约定）。
///
/// 手工构造的不同步实例不会崩：`effective_boxes()` 取两者较小值兜底，
/// 于是它退化成「一致的最小盒数」，而不是两个字段自相矛盾；**空表**
/// （`intervals: []`）另行按 1 天兜底，见 `interval_of`（第十三轮审计，P1：
/// 修复前空表会在 `interval_of` 里数组越界 panic）。
pub fn Leitner::with_intervals(
  boxes : Int32,
  intervals : Array[Double],
) -> Result[Leitner, String] {
  let n = intervals.length()
  if boxes < 1 {
    return Err("boxes 必须 >= 1，得到 \{boxes}")
  }
  if n != boxes {
    return Err(
      "intervals 的长度必须等于 boxes（\{boxes}），得到 \{n}",
    )
  }
  Ok({ boxes, intervals: intervals.copy(), })
}

///|
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
/// 越界的盒号夹到 [1, effective_boxes()]（`boxes` 与 `intervals` 长度的较小者）。
///
/// **上限夹取（RC-2，2026-10-27）**：结果同样夹到 `max_interval_days()`
/// （100 年）。Leitner 借 `CardState.interval_days` 表达盒间隔，与
/// SM-2 / FSRS 是同一字段同一语义（见 `types.mbt` 的字段说明），因此
/// 必须同受上限约束。
///
/// 为什么必须夹：`Leitner::with_boxes(n)` 的间隔表是 2 的幂
/// （1, 2, 4, 8, …），`n >= 17` 时最后一盒就已越界（2^16 = 65536 天）；
/// `intervals` 又是 `pub(all)` 字段，外部还能直接塞进 1e30。
/// 旧实现只靠 `add_days` 夹住了 `due`，`interval_days` 裸赋值，于是
/// 同一个 CardState 里两个字段相差最多 2.7e25 倍：
///   boxes=20  interval_days=524288 而 due-last_review=36500
/// 后果是 compare 的 total_interval、stats 的 mean/max_interval、
/// export_anki_tsv 的 interval_days 列、retrievability 的分母全部失真，
/// 且没有任何告警。
fn Leitner::effective_boxes(self : Leitner) -> Int32 {
  let n = self.intervals.length()
  if n < 1 {
    1
  } else if self.boxes < 1 {
    1
  } else if self.boxes > n {
    n
  } else {
    self.boxes
  }
}

///|
/// 盒号（1-based）→ 间隔天数。
fn Leitner::interval_of(self : Leitner, box : Int32) -> Double {
  let last = self.effective_boxes()
  let b = if box < 1 { 1 } else if box > last { last } else { box }
  // **空间隔表**（第十三轮审计，P1）：`effective_boxes()` 对空表按「至少一盒」
  // 的约定返回 1（盒号是 1-based，`leitner_box_of` 也把 0 读成盒 1），但表里
  // 没有任何一项可读。修复前这里直接 `intervals[b - 1]` = `intervals[0]` ——
  // 手工构造 `{ boxes: n, intervals: [] }` 之后第一次 `init` / `review` 就
  // **数组下标越界 panic**（wasm `unreachable`，进程级崩溃），而 `API.md` §3.3
  // 明文写着「手工构造的不同步实例不会崩」。第十二轮把「盒数只有一个来源」
  // 收敛到 `effective_boxes()` 时只论证了 `n >= 1` 这一端。
  //
  // 空表按 1 天兜底（与「表项为 NaN / 非正值」同一个兜底值），于是退化语义
  // 是自洽的：盒 1、间隔 1 天、每天到期。可达性 = `pub(all)` 直构
  // （DISCIPLINE §5.4）；带校验的 `Leitner::with_intervals(0, [])` 会 Err。
  if b - 1 >= self.intervals.length() {
    return 1.0
  }
  let raw = self.intervals[b - 1]
  // 与 sm2_next_interval / fsrs interval_days 同法：源头夹到
  // [1, max_interval_days()]，NaN 与负数兜底成 1 天。
  if raw.is_nan() || raw < 1.0 {
    1.0
  } else if raw > max_interval_days() {
    max_interval_days()
  } else {
    raw
  }
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
  // 盒号上界与 `interval_of` 用**同一个**来源（`effective_boxes`）。修复前这里
  // 用 `self.boxes`、`interval_of` 用 `intervals.length()`，手工构造的不同步
  // 实例会得到「盒 10 但间隔 1 天」这种自相矛盾的卡（第十二轮审计，P3）。
  let boxes = self.effective_boxes()
  let box = if !pass {
    1
  } else if prev_box >= boxes {
    boxes
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
