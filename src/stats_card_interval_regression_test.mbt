///|
test "curve review regression: first reviews of distinct cards are not intervals" {
  let log = ReviewLog::new()
  log.push(ReviewEvent::new("A", 0L, 0L, Good, 0.0))
  log.push(ReviewEvent::new("B", 86400L, 86400L, Again, 0.0))
  assert_eq(retention_curve(log, 2).length(), 0)
}

///|
test "curve review regression: interleaving and file order cannot change samples" {
  let a0 = ReviewEvent::new("A", 0L, 0L, Good, 0.0)
  let a1 = ReviewEvent::new("A", 864000L, 0L, Again, 0.0)
  let b0 = ReviewEvent::new("B", 86400L, 0L, Good, 0.0)
  let b1 = ReviewEvent::new("B", 172800L, 0L, Good, 0.0)
  let ordered = ReviewLog::{ events: [a0, b0, b1, a1], }
  let shuffled = ReviewLog::{ events: [a1, b1, a0, b0], }
  let curve = retention_curve(ordered, 2)
  assert_eq(curve, retention_curve(shuffled, 2))
  assert_eq(curve, [(5.0, 1.0), (10.0, 0.0)])
  let stats = compute_stats(shuffled)
  assert_eq(stats[0].mean_interval, 10.0)
  assert_eq(stats[1].mean_interval, 1.0)
}

///|
test "curve review regression: observed first interval has the same stats meaning" {
  let log = ReviewLog::{ events: [ReviewEvent::new("A", 0L, 0L, Hard, 5.0)], }
  assert_eq(compute_stats(log)[0].mean_interval, 5.0)
  assert_eq(overall_stats(compute_stats(log)).mean_interval, 5.0)
  assert_eq(retention_curve(log, 1), [(5.0, 1.0)])
}

///|
test "curve review regression: repeated zero elapsed reviews remain observations" {
  let log = ReviewLog::new()
  log.push(ReviewEvent::new("A", 0L, 0L, Good, 0.0))
  log.push(ReviewEvent::new("A", 0L, 0L, Again, 0.0))
  assert_eq(retention_curve(log, 10), [(0.0, 0.0)])
}
