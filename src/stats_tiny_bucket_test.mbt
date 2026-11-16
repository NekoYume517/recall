///|
/// 有限正间隔可以小到 `max / buckets` 在 Double 中下溢为 0。
/// 此时退化成单个真实范围桶，不能拿 1 天冒充原桶宽。
test "curve-edge: 桶宽下溢时保留真实最大间隔上界" {
  let tiny = 5.0e-324
  let log = ReviewLog::new()
  log.push(ReviewEvent::new("tiny", 0L, 0L, Good, 0.0))
  log.push(ReviewEvent::new("tiny", 86400L, 0L, Good, tiny))
  let curve = retention_curve(log, 10)
  assert_eq(curve.length(), 1)
  assert_eq(curve[0].0, 0.0)
  assert_eq(curve[0].1, tiny)
  assert_eq(curve[0].2, 1.0)
}

///|
test "curve-edge: 桶宽下溢的零间隔与正间隔仍合并计数" {
  let tiny = 5.0e-324
  let log = ReviewLog::new()
  log.push(ReviewEvent::new("tiny", 0L, 0L, Good, 0.0))
  log.push(ReviewEvent::new("tiny", 0L, 0L, Again, 0.0))
  log.push(ReviewEvent::new("tiny", 86400L, 0L, Good, tiny))
  let curve = retention_curve(log, 10)
  assert_eq(curve.length(), 1)
  assert_eq(curve[0].0, 0.0)
  assert_eq(curve[0].1, tiny)
  assert_eq(curve[0].2, 0.5)
}
