// recall — 统计测试（白盒）
//
// 核心属性：`retention_curve` 必须随 elapsed 单调不增。
// 这是整套实现的合理性检验点——任何公式写错都会在这里暴露。

// ---------------------------------------------------------------------------
// compute_stats
// ---------------------------------------------------------------------------

///|
/// 造日志：
///   a: Good(0) Good(1) Good(7)      → 3 次，0 遗忘，间隔 1、7
///   b: Good(0) Again(2) Good(1)     → 3 次，1 遗忘，间隔 2、1
fn stats_log() -> ReviewLog {
  let log = ReviewLog::new()
  log.push(ReviewEvent::new("a", 0L, 0L, Good, 0.0))
  log.push(ReviewEvent::new("a", 86400L, 86400L, Good, 1.0))
  log.push(ReviewEvent::new("a", 86400L * 8L, 86400L * 8L, Good, 7.0))
  log.push(ReviewEvent::new("b", 0L, 0L, Good, 0.0))
  log.push(ReviewEvent::new("b", 86400L * 2L, 86400L * 2L, Again, 2.0))
  log.push(ReviewEvent::new("b", 86400L * 3L, 86400L * 3L, Good, 1.0))
  log
}

///|
test "stats: 每张卡一行，按 card_id 升序" {
  let rows = compute_stats(stats_log())
  assert_eq(rows.length(), 2)
  assert_eq(rows[0].card_id, "a")
  assert_eq(rows[1].card_id, "b")
}

///|
test "stats: 复习次数正确" {
  let rows = compute_stats(stats_log())
  assert_eq(rows[0].reviews, 3)
  assert_eq(rows[1].reviews, 3)
}

///|
test "stats: 遗忘次数只数 Again" {
  let rows = compute_stats(stats_log())
  assert_eq(rows[0].lapses, 0)
  assert_eq(rows[1].lapses, 1)
}

///|
test "stats: Hard 算成功回忆（不算遗忘）" {
  // 这是 is_recalled 语义的关键断言：Hard 的 q=3，SM-2 里算答对
  let log = ReviewLog::new()
  log.push(ReviewEvent::new("h", 0L, 0L, Hard, 0.0))
  let rows = compute_stats(log)
  assert_eq(rows[0].lapses, 0)
  assert_true(near(rows[0].retention_rate, 1.0))
}

///|
test "stats: retention_rate 全对为 1" {
  let rows = compute_stats(stats_log())
  assert_true(near(rows[0].retention_rate, 1.0))
}

///|
test "stats: retention_rate 2/3 正确" {
  let rows = compute_stats(stats_log())
  assert_true(near(rows[1].retention_rate, 2.0 / 3.0))
}

///|
test "stats: mean_interval 只统计有上一次的样本" {
  let rows = compute_stats(stats_log())
  // a: 间隔 1 和 7 → 均值 4
  assert_true(near(rows[0].mean_interval, 4.0))
  // b: 间隔 2 和 1 → 均值 1.5
  assert_true(near(rows[1].mean_interval, 1.5))
}

///|
test "stats: max_interval 取最大值" {
  let rows = compute_stats(stats_log())
  assert_true(near(rows[0].max_interval, 7.0))
  assert_true(near(rows[1].max_interval, 2.0))
}

///|
test "stats: 空日志返回空数组" {
  let rows = compute_stats(ReviewLog::new())
  assert_eq(rows.length(), 0)
}

///|
test "stats: 单次复习的间隔统计为 0（没有上一个间隔）" {
  let log = ReviewLog::new()
  log.push(ReviewEvent::new("x", 0L, 0L, Good, 0.0))
  let rows = compute_stats(log)
  assert_eq(rows.length(), 1)
  assert_eq(rows[0].reviews, 1)
  assert_true(near(rows[0].mean_interval, 0.0))
  assert_true(near(rows[0].max_interval, 0.0))
}

///|
test "stats: elapsed_days 缺失时按时间戳回推" {
  let log = ReviewLog::new()
  // 两条事件的 elapsed_days 都是 0，但时间戳差 5 天
  log.push(ReviewEvent::new("x", 0L, 0L, Good, 0.0))
  log.push(ReviewEvent::new("x", 86400L * 5L, 0L, Good, 0.0))
  let rows = compute_stats(log)
  assert_true(near(rows[0].mean_interval, 5.0))
}

///|
test "stats: retention_rate 永远落在 [0,1]" {
  let rows = compute_stats(stats_log())
  for r in rows {
    assert_true(r.retention_rate >= 0.0)
    assert_true(r.retention_rate <= 1.0)
  }
}

// ---------------------------------------------------------------------------
// overall_stats
// ---------------------------------------------------------------------------

///|
test "stats: overall_stats 汇总次数与遗忘" {
  let rows = compute_stats(stats_log())
  let o = overall_stats(rows)
  assert_eq(o.cards, 2)
  assert_eq(o.reviews, 6)
  assert_eq(o.lapses, 1)
}

///|
test "stats: overall_stats 保持率 = (总复习-总遗忘)/总复习" {
  let rows = compute_stats(stats_log())
  let o = overall_stats(rows)
  assert_true(near(o.retention_rate, 5.0 / 6.0))
}

///|
test "stats: overall_stats 空输入不除零" {
  let o = overall_stats([])
  assert_eq(o.cards, 0)
  assert_eq(o.reviews, 0)
  assert_true(near(o.retention_rate, 0.0))
  assert_true(near(o.mean_interval, 0.0))
}

// ---------------------------------------------------------------------------
// retention_curve：核心单调性
// ---------------------------------------------------------------------------

///|
test "curve: 空日志返回空曲线" {
  assert_eq(retention_curve(ReviewLog::new(), 10).length(), 0)
}

///|
test "curve: 只有首次复习（elapsed=0）时无样本" {
  let log = ReviewLog::new()
  log.push(ReviewEvent::new("x", 0L, 0L, Good, 0.0))
  assert_eq(retention_curve(log, 5).length(), 0)
}

///|
test "curve: bucket 上界严格递增" {
  let c = retention_curve(stats_log(), 4)
  assert_true(c.length() > 0)
  let mut prev = 0.0
  for row in c {
    assert_true(row.0 > prev)
    prev = row.0
  }
}

///|
test "curve: 保持率落在 [0,1]" {
  let c = retention_curve(stats_log(), 4)
  for row in c {
    assert_true(row.1 >= 0.0)
    assert_true(row.1 <= 1.0)
  }
}

///|
test "curve: 桶数不超过请求值" {
  let c = retention_curve(stats_log(), 3)
  assert_true(c.length() <= 3)
}

///|
/// 构造"间隔越长越容易忘"的日志：三组各 10 张卡，间隔 1 / 10 / 100 天，
/// 保持率分别是 10/10、5/10、1/10。
fn monotone_log() -> ReviewLog {
  let log = ReviewLog::new()
  // 短间隔（1 天）：全对
  let mut i = 0
  while i < 10 {
    let ts = (i + 1).to_int64() * 86400L
    log.push(ReviewEvent::new("s" + i.to_string(), ts, ts, Good, 1.0))
    i = i + 1
  }
  // 中间隔（10 天）：一半对
  let mut j = 0
  while j < 10 {
    let ts = (j + 1).to_int64() * 86400L
    let even = j % 2 == 0
    let g : Grade = if even { Good } else { Again }
    log.push(ReviewEvent::new("m" + j.to_string(), ts, ts, g, 10.0))
    j = j + 1
  }
  // 长间隔（100 天）：只剩 1 个对
  let mut k = 0
  while k < 10 {
    let ts = (k + 1).to_int64() * 86400L
    let first = k == 0
    let g : Grade = if first { Good } else { Again }
    log.push(ReviewEvent::new("l" + k.to_string(), ts, ts, g, 100.0))
    k = k + 1
  }
  log
}

///|
test "curve: 保持率随间隔单调不增（核心属性）" {
  let c = retention_curve(monotone_log(), 10)
  assert_true(c.length() >= 3)
  let mut prev = 1.1
  for row in c {
    assert_true(row.1 <= prev)
    prev = row.1
  }
}

///|
test "curve: 短间隔桶的保持率严格高于长间隔桶" {
  let c = retention_curve(monotone_log(), 10)
  let first = c[0].1
  let last = c[c.length() - 1].1
  assert_true(first > last)
}

///|
test "curve: 全对日志的保持率恒为 1" {
  let log = ReviewLog::new()
  let mut i = 0
  while i < 20 {
    let day = (i + 1).to_int64()
    let ts = day * 86400L
    log.push(
      ReviewEvent::new("c" + i.to_string(), ts, ts, Good, day.to_double()),
    )
    i = i + 1
  }
  let c = retention_curve(log, 5)
  assert_true(c.length() > 0)
  for row in c {
    assert_true(near(row.1, 1.0))
  }
}

///|
test "curve: 全忘日志的保持率恒为 0" {
  let log = ReviewLog::new()
  let mut i = 0
  while i < 20 {
    let day = (i + 1).to_int64()
    let ts = day * 86400L
    log.push(
      ReviewEvent::new("c" + i.to_string(), ts, ts, Again, day.to_double()),
    )
    i = i + 1
  }
  let c = retention_curve(log, 5)
  assert_true(c.length() > 0)
  for row in c {
    assert_true(near(row.1, 0.0))
  }
}

///|
test "curve: buckets=1 时只有一个桶，覆盖全部样本" {
  let c = retention_curve(monotone_log(), 1)
  assert_eq(c.length(), 1)
  // 通过 10 + 5 + 1 = 16，总 30
  assert_true(near(c[0].1, 16.0 / 30.0))
}

///|
test "curve: buckets < 1 被当作 1" {
  let c0 = retention_curve(monotone_log(), 0)
  assert_eq(c0.length(), 1)
  let cneg = retention_curve(monotone_log(), -5)
  assert_eq(cneg.length(), 1)
}

///|
test "curve: buckets 很大时也只是把样本摊开，不产生假数据" {
  let c = retention_curve(monotone_log(), 100)
  // 只有 3 个非零间隔值（1/10/100），因此非空桶最多 3 个
  assert_true(c.length() <= 3)
  assert_true(c.length() > 0)
}

///|
test "curve: 最大 elapsed 落在最后一桶（桶上界覆盖它）" {
  let log = ReviewLog::new()
  log.push(ReviewEvent::new("x", 0L, 0L, Good, 0.0))
  log.push(ReviewEvent::new("x", 86400L * 30L, 0L, Good, 30.0))
  let c = retention_curve(log, 3)
  let last_upper = c[c.length() - 1].0
  assert_true(last_upper >= 30.0 - 0.000000001)
}

///|
test "curve: Hard 计入成功（与 is_recalled 一致）" {
  let log = ReviewLog::new()
  log.push(ReviewEvent::new("x", 0L, 0L, Hard, 5.0))
  log.push(ReviewEvent::new("y", 0L, 0L, Again, 5.0))
  let c = retention_curve(log, 1)
  assert_eq(c.length(), 1)
  // 2 个样本，1 个成功 → 0.5
  assert_true(near(c[0].1, 0.5))
}

///|
test "curve: 单调性在真实示例日志上也成立" {
  // 用 examples/reviews.jsonl 里的间隔序列（0/1/3/8/21）
  let log = ReviewLog::new()
  for cid in ["c1", "c2"] {
    log.push(ReviewEvent::new(cid, 0L, 0L, Good, 0.0))
    log.push(ReviewEvent::new(cid, 86400L, 0L, Easy, 1.0))
    log.push(ReviewEvent::new(cid, 86400L * 4L, 0L, Easy, 3.0))
    log.push(ReviewEvent::new(cid, 86400L * 12L, 0L, Good, 8.0))
    log.push(ReviewEvent::new(cid, 86400L * 33L, 0L, Easy, 21.0))
  }
  let c = retention_curve(log, 5)
  assert_true(c.length() > 0)
  let mut prev = 1.1
  for row in c {
    assert_true(row.1 <= prev)
    prev = row.1
  }
}
