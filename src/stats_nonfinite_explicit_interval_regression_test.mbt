// 回归：公开事件构造器允许的非有限显式间隔，统计与 JSONL 落零口径不一致。
//
// ReviewEvent::new 原样保留 +Infinity；to_jsonl 的全字段出口把它规范化为 0。
// 但 stats.review_interval 只判断 `elapsed_days > 0`，于是内存统计把 +Infinity
// 当成样本，序列化再读回却把同一事件按 0 回推。后续有限样本还会令增量均值
// 执行 `Infinity - Infinity`，得到 NaN。

///|
fn stats_nonfinite_interval_log() -> ReviewLog {
  let log = ReviewLog::new()
  log.push(ReviewEvent::new("c1", 0L, 0L, Grade::Good, 1.0))
  log.push(ReviewEvent::new("c1", 86400L, 86400L, Grade::Good, 1.0 / 0.0))
  log.push(ReviewEvent::new("c1", 172800L, 172800L, Grade::Hard, 2.0))
  log
}

///|
test "stats nonfinite explicit interval: 内存与 JSONL 读回使用同一回推口径" {
  let log = stats_nonfinite_interval_log()
  let before = compute_stats(log)
  let parsed = ReviewLog::from_jsonl(log.to_jsonl()) catch {
    _ => fail("自身序列化输出应可读回")
  }
  let after = match parsed {
    Ok(back) => compute_stats(back)
    Err(_) => fail("自身序列化输出应可读回")
  }
  assert_eq(before.length(), 1)
  assert_eq(after.length(), 1)
  // 三条事件的间隔应为 1、回推 1、显式 2，均值 4/3、最大 2。
  assert_true((after[0].mean_interval - 4.0 / 3.0).abs() < 0.000000001)
  assert_eq(after[0].max_interval, 2.0)
  assert_true(
    (before[0].mean_interval - after[0].mean_interval).abs() < 0.000000001,
  )
  assert_eq(before[0].max_interval, after[0].max_interval)
  assert_true(before[0].mean_interval - before[0].mean_interval == 0.0)
  assert_true(before[0].mean_interval <= before[0].max_interval)
}

///|
test "stats nonfinite explicit interval: retention_curve 不接收无穷样本" {
  let curve = retention_curve(stats_nonfinite_interval_log(), 3)
  assert_true(curve.length() > 0)
  for bucket in curve {
    assert_true(bucket.0 >= 0.0)
    assert_true(bucket.1 < 1.0 / 0.0)
    assert_true(bucket.1 <= 2.0)
    assert_true(bucket.2 >= 0.0 && bucket.2 <= 1.0)
  }
}
