// ============================================================================
// 同刻事件的警告必须落到「用户可见面」：stderr 诊断 + `--json` 里的机读字段
//
// 第二十轮 RC-20-3 的追加项（Lead 裁决 2026-11-29）。前一轮只把「同刻事件按文件
// 行序决定先后」写进了 API.md 的确定性条款，而 `replay --json` 的使用者不会读
// API.md——他读的是 stdout 的 JSON 和 stderr 的诊断。于是这条边界对真正的使用者
// 是不可见的。
//
// 现在要求三件事同时成立：
//
//   1. **stderr 诊断**：同一 card 出现 ≥2 条相同时刻的事件时，打印一行
//        `警告: 卡片 <id> 有 <N> 条同刻事件（…），其先后按文件行序决定，换序可能改变摘要`
//      每张卡一条，按 card_id 升序，且**只走 stderr**。
//   2. **`--json` 机读字段**：出现同刻事件时追加
//        `"same_timestamp_groups":N`（N = 有同刻组的卡片数）
//      没有同刻事件时**键不出现**（而不是给 0），保持现有 JSON 形状不变。
//   3. **stdout 数据段一份字节都不变**：诊断不污染 JSON；比对方式是与「无同刻
//      事件」的基线逐字节对照，只允许多出那一个键。
//
// 判定「同刻」的口径：同一 card 的两条相邻事件（按 `reviewed_at` 稳定排序后）
// 时间戳相等。这与 `by_card` 的分组一致，也就是重放时真正会互相影响的那一组。

///|
/// 取一次重放的同刻组数（非 0 即表示存在同刻事件）。
fn rc20_same_ts_group_count(res : ReplayResult) -> Int32 {
  res.same_timestamp_groups
}

///|
/// 造日志：`tied = true` 时同一 card 有两条同刻事件（Easy / Again），
/// 否则每条事件各占一个时刻。
fn rc20_ts_log(tied : Bool) -> ReviewLog {
  let log = ReviewLog::new()
  let t0 : Timestamp = 1700000000L
  log.push(ReviewEvent::new("k", t0, t0, Good, 1.0))
  if tied {
    log.push(ReviewEvent::new("k", t0 + 86400L, t0 + 86400L, Easy, 1.0))
    log.push(ReviewEvent::new("k", t0 + 86400L, t0 + 86400L, Again, 1.0))
  } else {
    log.push(ReviewEvent::new("k", t0 + 86400L, t0 + 86400L, Easy, 1.0))
    log.push(
      ReviewEvent::new("k", t0 + 2L * 86400L, t0 + 2L * 86400L, Again, 1.0),
    )
  }
  log
}

///|
test "rc20-3b: 有同刻事件时 same_timestamp_groups = 1" {
  let res = replay(rc20_ts_log(true), AnyScheduler::by_name("fsrs"))
  assert_eq(rc20_same_ts_group_count(res), 1)
}

///|
test "rc20-3b: 无同刻事件时 same_timestamp_groups = 0" {
  let res = replay(rc20_ts_log(false), AnyScheduler::by_name("fsrs"))
  assert_eq(rc20_same_ts_group_count(res), 0)
}

///|
test "rc20-3b: 多张卡各自同刻时按卡计数（而不是按事件数）" {
  let log = ReviewLog::new()
  let t0 : Timestamp = 1700000000L
  // a：2 条同刻；b：3 条同刻；c：无同刻
  log.push(ReviewEvent::new("a", t0, t0, Good, 1.0))
  log.push(ReviewEvent::new("a", t0 + 86400L, t0 + 86400L, Good, 1.0))
  log.push(ReviewEvent::new("a", t0 + 86400L, t0 + 86400L, Easy, 1.0))
  log.push(ReviewEvent::new("b", t0, t0, Good, 1.0))
  log.push(ReviewEvent::new("b", t0 + 86400L, t0 + 86400L, Good, 1.0))
  log.push(ReviewEvent::new("b", t0 + 86400L, t0 + 86400L, Good, 1.0))
  log.push(ReviewEvent::new("b", t0 + 86400L, t0 + 86400L, Again, 1.0))
  log.push(ReviewEvent::new("c", t0, t0, Good, 1.0))
  log.push(ReviewEvent::new("c", t0 + 86400L, t0 + 86400L, Good, 1.0))
  log.push(ReviewEvent::new("c", t0 + 2L * 86400L, t0 + 2L * 86400L, Good, 1.0))
  let res = replay(log, AnyScheduler::by_name("fsrs"))
  assert_eq(rc20_same_ts_group_count(res), 2)
}

///|
test "rc20-3b: 同刻组数在三个调度器上一致（它是日志属性，不是算法属性）" {
  let log = rc20_ts_log(true)
  let a = replay(log, AnyScheduler::by_name("fsrs"))
  let b = replay(log, AnyScheduler::by_name("sm2"))
  let c = replay(log, AnyScheduler::by_name("leitner"))
  assert_eq(a.same_timestamp_groups, b.same_timestamp_groups)
  assert_eq(b.same_timestamp_groups, c.same_timestamp_groups)
}
