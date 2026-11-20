// 回归：replay 的「实际间隔」没有走非有限守卫。
//
// API.md §2（行 144-145）把口径写成全局约定：**下游只采用「有限且 > 0」的
// elapsed_days 字面值，否则按同卡前驱时间戳回推**；src/log.mbt 行 244-247
// 更点名 `review_interval` / `replay_with`，并据此断言「内存里那份和写出去
// 再读回来那份在 stats / replay 上逐字段相同」。
//
// 但 `replay_with` 的实际间隔仍是 `if ev.elapsed_days > 0.0`——`+Infinity`
// 通过了这个比较。于是：
//   - 内存重放把 +Infinity 当样本 → `diff = Infinity - scheduled = Infinity`；
//   - 再来一条有限样本时增量均值执行 `Infinity - Infinity` → **NaN**；
//   - 同一日志 to_jsonl（落 0）再读回重放，却是有限的回推值。
// 与 2026-11-20 修的 stats 同族，replay 侧是漏掉的镜像入口。

///|
fn replay_nonfinite_interval_log() -> ReviewLog {
  let log = ReviewLog::new()
  log.push(ReviewEvent::new("c1", 0L, 0L, Grade::Good, 1.0))
  log.push(ReviewEvent::new("c1", 86400L, 86400L, Grade::Good, 1.0 / 0.0))
  log.push(ReviewEvent::new("c1", 172800L, 172800L, Grade::Hard, 2.0))
  log
}

///|
fn is_finite(x : Double) -> Bool {
  !x.is_nan() && x != 1.0 / 0.0 && x != -1.0 / 0.0
}

///|
test "replay nonfinite explicit interval: 内存与 JSONL 读回使用同一回推口径" {
  let log = replay_nonfinite_interval_log()
  let before = replay(log, AnyScheduler::Fsrs(Fsrs::new()))
  let parsed = ReviewLog::from_jsonl(log.to_jsonl()) catch {
    _ => fail("自身序列化输出应可读回")
  }
  let after = match parsed {
    Ok(back) => replay(back, AnyScheduler::Fsrs(Fsrs::new()))
    Err(_) => fail("自身序列化输出应可读回")
  }
  assert_eq(before.total_reviews, 3)
  assert_eq(after.total_reviews, 3)
  // +Infinity 不进入均值：第 2 条按同卡前驱回推成 1 天，第 3 条显式 2 天。
  assert_true(is_finite(before.interval_error_days))
  assert_true(before.interval_error_days >= 0.0)
  // 往返：内存那份必须与落盘再读回来的那份逐字段相同。
  assert_true(
    (before.interval_error_days - after.interval_error_days).abs() < 0.000000001,
  )
}

///|
test "replay nonfinite explicit interval: 单条无穷样本不产生 NaN" {
  // 只留两条：第二条显式 +Infinity。修复前 error_mean 直接是 Infinity
  // （两条时还到不了 NaN，单条已足够说明「无穷进了均值」）。
  let log = ReviewLog::new()
  log.push(ReviewEvent::new("c1", 0L, 0L, Grade::Good, 1.0))
  log.push(ReviewEvent::new("c1", 86400L, 86400L, Grade::Good, 1.0 / 0.0))
  let res = replay(log, AnyScheduler::Fsrs(Fsrs::new()))
  assert_true(is_finite(res.interval_error_days))
  assert_true(res.interval_error_days <= max_interval_days())
}
