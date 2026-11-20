// 回归（2026-11-21 审计，#6）：`retention_curve` 的归桶从「从 0 线性上扫」
// 改成 O(1)（除法起点 + 与标签同源的乘法校正）。
//
// 旧实现最坏 samples × buckets 次比较：1e5 事件 × `--buckets 10000` 实测
// 1.38 s（buckets=100 为 0.76 s），归桶占掉约 0.7 s；改动后 10000 桶与
// 100 桶同量级（0.66 s vs 0.78 s，解析/分组是主项）。实测见
// audit/2026-11-21/recall/evidence/curve-buckets-bench.log。
//
// 这里锁住 O(1) 起点的两个边界：
//   1. `iv == max_elapsed` 时 `iv / width` 恰好等于 buckets，必须封顶到
//      最后一桶（末桶是闭区间 `[lo, hi]`）；
//   2. 中间桶沿的样本仍落在「标签含自己」的桶（RC-8 的乘法判定不变）。
//
// 全零样本的退化桶、下溢桶宽等既有语义由 stats_bucket_edge_regression_test /
// stats_tiny_bucket_test 覆盖。

///|
fn curve_log_with_intervals(intervals : Array[Double]) -> ReviewLog {
  let log = ReviewLog::new()
  let mut t = 0L
  for i, iv in intervals {
    if i == 0 {
      log.push(ReviewEvent::new("c", t, t, Grade::Good, 0.0))
    } else {
      log.push(ReviewEvent::new("c", t, t, Grade::Good, iv))
    }
    t = t + (iv * 86400.0).to_int64()
  }
  log
}

///|
test "retention_curve: 最大间隔样本封顶到末桶，桶数再大也不越界" {
  let ivs : Array[Double] = []
  for _ in 0..<50 {
    ivs.push(1000.0)
  }
  let log = curve_log_with_intervals(ivs)
  let curve = retention_curve(log, 10000)
  // 50 个样本全部 iv=1000=max ⇒ 全部落在末桶 [999.9, 1000.0]。
  assert_eq(curve.length(), 1)
  let b = curve[0]
  assert_true(approx_default(b.0, 999.9))
  assert_true(approx_default(b.1, 1000.0))
  assert_eq(b.2, 1.0)
}

///|
test "retention_curve: 中间桶沿样本仍被自己的标签覆盖（RC-8 判定不变）" {
  // max=180, buckets=7 ⇒ width=180/7；样本 iv=180*3/7 数学上正好在桶沿。
  let width = 180.0 / 7.0
  let iv = 180.0 * 3.0 / 7.0
  let log = ReviewLog::new()
  log.push(ReviewEvent::new("c", 0L, 0L, Grade::Good, 0.0))
  log.push(ReviewEvent::new("c", 86400L, 86400L, Grade::Good, iv))
  log.push(ReviewEvent::new("c", 86400L + 1L, 86400L + 1L, Grade::Good, 180.0))
  let curve = retention_curve(log, 7)
  // 找到包含 iv 的桶：low <= iv < high（末桶允许闭区间）。
  let mut found = false
  for (lo, hi, _) in curve {
    if iv >= lo && iv <= hi {
      found = true
    }
  }
  assert_true(found)
  assert_true(curve[curve.length() - 1].1 >= 180.0)
  assert_true(width * 3.0 == iv)
}
