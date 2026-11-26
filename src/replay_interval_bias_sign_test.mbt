// ============================================================================
// replay 的「间隔偏差」：计划值必须来自日志，方向必须可读
//
// 现象（第十九轮 RC-19-2，2026-11-27，native release 实测）：
//
//   同一张卡、同样的两次复习时刻，只把第二次事件的 `due_at`（= "当时系统
//   认为的到期时间"，日志里唯一记录调度意图的字段）向早/向晚挪：
//
//        gap=30 天、elapsed=30，due_at 取 t0+6/8/12 天 → 偏差 24/22/18 天
//        gap=30 天、elapsed=30，due_at 取 t0+20/25/30 天 → 偏差 10/5/0 天
//
//   也就是说：**旧实现里 `interval_error_days` 与 `due_at` 毫无关系**——
//   它恒等于 |日志实际间隔 − 重放到此刻的调度器自己给出的 interval_days|。
//   结构体注释（"上次调度给出的间隔"）与 API.md §4 都指向 `due_at`，实现却
//   取的是调度器的理想值；于是这个指标衡量的是"用户节奏 vs 调度器设定"，
//   而不是"计划 vs 实际"，也永远看不见逾期/提前这两个相反方向。
//
// 修法（不破坏既有字段口径，只把计划值换回日志真值）：
//   * `scheduled = (due_at − 上一条 reviewed_at) / 86400`（负数按 0）；
//     首条事件无前驱，沿用调度器初始化值。
//   * 新增 `signed_interval_error_days`（逾期为正、提前为负）与
//     `late_review_ratio`（逾期样本占比）。
//
// 标尺数据（gap=9 天、显式 elapsed_days=9、FSRS）：
//
//     due_at = t0+9  → 0.0000     due_at = t0+15 → 6.0000
//     due_at = t0+11 → 2.0000     due_at = t0+19 → 10.0000
//
// 本文件的断言全部围绕"计划 = due_at − 上次复习"这一条定义展开。

///|
/// 造一份两事件日志：第 1 次在 t0，第 2 次在 t0 + `gap_days` 天。
/// 第 2 次的 `due_at` 落在 t0 + `due_days` 天，`elapsed_days` 显式写成
/// `gap_days`（避免走"时间戳回推"那条分支，读数才干净）。
fn rc19_two_event_log(gap_days : Int64, due_days : Int64) -> ReviewLog {
  let log = ReviewLog::new()
  let t0 : Timestamp = 1700000000L
  log.push(ReviewEvent::new("k", t0, t0, Good, 1.0))
  log.push(
    ReviewEvent::new(
      "k",
      t0 + 86400L * gap_days,
      t0 + 86400L * due_days,
      Good,
      gap_days.to_double(),
    ),
  )
  log
}

///|
test "rc19-2: 计划值取自 due_at——偏差随 due_at 单调变化" {
  // gap 9 天；计划 9 / 11 / 14 / 19 天 → 偏差 0 / 2 / 5 / 10 天
  let cases : Array[(Int64, Double)] = [
    (9L, 0.0),
    (11L, 2.0),
    (14L, 5.0),
    (19L, 10.0),
  ]
  for pair in cases {
    let res = replay(
      rc19_two_event_log(9L, pair.0),
      AnyScheduler::by_name("fsrs"),
    )
    let diff = (res.interval_error_days - pair.1).abs()
    assert_true(diff < 1.0e-9)
  }
}

///|
test "rc19-2: 逾期复习：带符号偏差为正、逾期占比 1" {
  // gap 30 天、计划 8 天 → 逾期 22 天
  let res = replay(rc19_two_event_log(30L, 8L), AnyScheduler::by_name("fsrs"))
  assert_true((res.interval_error_days - 22.0).abs() < 1.0e-9)
  assert_true((res.signed_interval_error_days - 22.0).abs() < 1.0e-9)
  assert_true(res.late_review_ratio == 1.0)
}

///|
test "rc19-2: 提前复习：带符号偏差为负、逾期占比 0" {
  // gap 9 天、计划 11 天 → 提前 2 天
  let res = replay(rc19_two_event_log(9L, 11L), AnyScheduler::by_name("fsrs"))
  assert_true((res.interval_error_days - 2.0).abs() < 1.0e-9)
  assert_true((res.signed_interval_error_days + 2.0).abs() < 1.0e-9)
  assert_true(res.late_review_ratio == 0.0)
}

///|
test "rc19-2: 一正一负等幅偏差互相抵消（绝对值统计量看不见）" {
  let log = ReviewLog::new()
  let t0 : Timestamp = 1600000000L
  // 卡 a：gap 30 天、计划 8 天 → 逾期 22 天
  log.push(ReviewEvent::new("a", t0, t0, Good, 1.0))
  log.push(
    ReviewEvent::new("a", t0 + 86400L * 30L, t0 + 86400L * 8L, Good, 30.0),
  )
  // 卡 b：gap 9 天、计划 11 天 → 提前 2 天——再配一张"平衡"样本太琐碎，
  // 直接换成等幅构造：gap 30 天、计划 38 天 → 提前 8 天
  log.push(ReviewEvent::new("b", t0, t0, Good, 1.0))
  log.push(
    ReviewEvent::new("b", t0 + 86400L * 30L, t0 + 86400L * 38L, Good, 30.0),
  )
  let res = replay(log, AnyScheduler::by_name("fsrs"))
  // 带符号：(+22 − 8)/2 = +7 → 总体逾期 7 天
  assert_true((res.signed_interval_error_days - 7.0).abs() < 1.0e-9)
  // 绝对值：(22 + 8)/2 = 15 —— 旧口径只有一个"误差"，两个方向被吃掉
  assert_true((res.interval_error_days - 15.0).abs() < 1.0e-9)
  // 两个样本里一个逾期
  assert_true((res.late_review_ratio - 0.5).abs() < 1.0e-9)
}
