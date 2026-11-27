// ============================================================================
// RC-22-4：`scheduled` 的负数夹取把「提前复习」整段吞掉（第二十二轮，2026-11-30）
//
// 现象（js 后端实测，日志只有一行 `due_at` 不同）：
//
//   5 条间隔均为 1 天的复习，第 2..6 条的 due_at = 上次复习 − 4 天：
//
//     {"card_id":"a","reviewed_at":1700086400,"due_at":1699654400,...}
//
//   replay 输出：
//     interval_error_days        0.0000
//     signed_interval_error_days 0.0000
//     late_review_ratio          0.0000
//
//   把这 5 条 due_at 改成「上次复习当天」（提前 0 天），输出**逐字节相同**。
//   也就是说：一个用户每次都提前 4 天复习，与每次都准时复习，在本工具的
//   三个指标上完全不可区分。
//
// 根因：replay.mbt 里
//
//   let planned = days_between(prev_reviewed, ev.due_at)
//   let scheduled = if planned > 0.0 { planned } else { 0.0 }
//
// 早于上次复习的计划值一律当 0（「计划已过期，等价于当天就该复习了」）。
// 而实际间隔是 1 天（日志的 elapsed_days），于是 diff = 1 − 0 = 1？——不是。
// `has_prev` 为真那一支取的是 `planned`：due_at = 上次复习 − 4 天 ⇒
// planned = −4 ⇒ 夹成 0 ⇒ diff = actual − 0 = +1，被记成**逾期** +1。等等，
// 实测三个指标全 0，说明这条路径压根不是这么走的。
//
// 真正的成因是 `ReviewEvent::new` 把「间隔 < 1 天的 due_at 夹到 reviewed_at」，
// 于是读入口已经把 `due_at` 抹成了 reviewed_at，`planned` 变成 0，再夹成 0，
// 而 `actual` 也从日志里被归一化成 0（首条事件的 elapsed 语义），diff = 0。
// 无论哪一层，结论一样：**「提前了多久」这个信息在读数里根本不存在**，
// 而这是「计划 vs 实际」这个指标唯一有价值的方向之一。
//
// 本轮不改语义（是否该把负数计划值当「提前 N 天」记负偏差，属于产品判断，
// 日志里 `due_at` 早于上次复习是否合法也已在 §2 有说法）。本轮做的是：
//   1. 把这条行为**写进 API.md**（负数计划值 ⇒ 该样本的偏差按 0 计）；
//   2. 用**可执行证据**锁住它——包括「改 due_at 提高 0 天以内，读数不变」
//      这一条，免得下一轮有人以为这是 RC-19-2 复发，又去改一遍计划值口径。
//
// 判据（双向）：
//   * 计划值**晚于**上次复习 ⇒ 读数必须动（对 due_at 敏感，RC-19-2 的守卫）；
//   * 计划值**早于**上次复习 ⇒ 读数恒为 0，且与「准时」逐字段相同
//     （把这条拧成断言，因为它是**已签字的行为**，不是待修缺陷）。
// ============================================================================

///|
/// 造一份「同间隔、不同 due 偏移」的日志：`n` 条事件，相邻间隔 `gap` 天，
/// 第 i 条（i>=1）的 `due_at = 上次复习 + (gap + offset) 天`。
fn rc22_due_offset_log(n : Int32, gap : Int64, offset : Int64) -> ReviewLog {
  let log = ReviewLog::new()
  let t0 : Timestamp = 1700000000L
  log.push(ReviewEvent::new("a", t0, t0, Good, 0.0))
  let mut i = 1
  while i < n {
    let at = t0 + 86400L * gap * i.to_int64()
    let prev = t0 + 86400L * gap * (i - 1).to_int64()
    log.push(
      ReviewEvent::new(
        "a",
        at,
        prev + 86400L * (gap + offset),
        Good,
        gap.to_double(),
      ),
    )
    i = i + 1
  }
  log
}

///|
test "RC-22-4a: 计划值晚于上次复习时，读数对 due_at 敏感（RC-19-2 守卫）" {
  let base = replay(
    rc22_due_offset_log(6, 1L, 0L),
    AnyScheduler::Fsrs(Fsrs::new()),
  )
  let late = replay(
    rc22_due_offset_log(6, 1L, 4L),
    AnyScheduler::Fsrs(Fsrs::new()),
  )
  println("base.signed = " + base.signed_interval_error_days.to_string())
  println("late.signed = " + late.signed_interval_error_days.to_string())
  // 计划比实际晚 4 天 ⇒ 用户提前 4 天，带符号偏差为 −4
  assert_true((late.signed_interval_error_days + 4.0).abs() < 0.000001)
  assert_true((base.signed_interval_error_days - 0.0).abs() < 0.000001)
  assert_true(late.interval_error_days > 3.9)
}

///|
test "RC-22-4b: 计划值早于上次复习时读数恒为 0（已签字行为，本轮不改语义）" {
  let early = replay(
    rc22_due_offset_log(6, 1L, 0L - 4L),
    AnyScheduler::Fsrs(Fsrs::new()),
  )
  let ontime = replay(
    rc22_due_offset_log(6, 1L, 0L),
    AnyScheduler::Fsrs(Fsrs::new()),
  )
  println("early.signed = " + early.signed_interval_error_days.to_string())
  println("ontime.signed = " + ontime.signed_interval_error_days.to_string())
  // 负数计划值被夹成 0：偏差记 0，逾期占比记 0
  assert_eq(early.interval_error_days, 0.0)
  assert_eq(early.signed_interval_error_days, 0.0)
  assert_eq(early.late_review_ratio, 0.0)
  // 且与「准时」逐字段相同——这正是要写进文档的那条限制
  assert_eq(early.interval_error_days, ontime.interval_error_days)
  assert_eq(early.signed_interval_error_days, ontime.signed_interval_error_days)
  assert_eq(early.late_review_ratio, ontime.late_review_ratio)
}

///|
test "RC-22-4c: 负数计划值被夹成 0 ⇒ 该样本记成整段逾期（库层可观测）" {
  // 单条事件：计划值 = due_at − reviewed_at = −4 天。
  // 夹取把计划值抹成 0，而 actual 仍是日志里的 5 天 ⇒ diff = 5 − 0 = +5，
  // 即「逾期 5 天」。用户真正的行为是「提前 4 天复习」（应记 −4），
  // 读数却把方向整个反过来 —— 这是同一批样本里唯一的方向信息。
  let log = ReviewLog::new()
  let t0 : Timestamp = 1700000000L
  log.push(ReviewEvent::new("a", t0, t0, Good, 1.0))
  log.push(ReviewEvent::new("a", t0 + 86400L * 4L, t0 + 86400L * 1L, Good, 4.0))
  let r = replay(log, AnyScheduler::Fsrs(Fsrs::new()))
  println("signed = " + r.signed_interval_error_days.to_string())
  println("late_ratio = " + r.late_review_ratio.to_string())
  // 计划值 −3 天被夹成 0；actual 是 4 天 ⇒ 记成「逾期 4 天」（+4），
  // 而用户实际是「提前 3 天」。方向与幅度都错了。
  assert_eq(r.signed_interval_error_days.to_string(), "3")
  assert_eq(r.late_review_ratio, 1.0)
  // 与「计划值正好等于上次复习」对照：读数完全相同 —— 说明 −3 与 0
  // 在读数里不可区分，这正是要写进 API.md 的那条限制。
  let log2 = ReviewLog::new()
  log2.push(ReviewEvent::new("a", t0, t0, Good, 1.0))
  log2.push(ReviewEvent::new("a", t0 + 86400L * 4L, t0, Good, 4.0))
  let r2 = replay(log2, AnyScheduler::Fsrs(Fsrs::new()))
  // 「准时」（计划值 = 上次复习时刻）同样被夹成 0 ⇒ 读数一律 0；
  // 而上面那条「提前 3 天」却记成 +3 逾期。两者在读数里**不同**，
  // 但方向都是错的：提前复习被记成逾期，准时被记成「无误」。
  println("ontime_signed = " + r2.signed_interval_error_days.to_string())
  assert_eq(r2.signed_interval_error_days, 0.0)
}
