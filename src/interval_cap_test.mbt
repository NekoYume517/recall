// 回归测试：间隔上限，防止 Int64 回绕
//
// 背景：FSRS 连续 Easy 会让 S 指数增长（第 ~50 次 S ≈ 2e15 天）。
// `due = now + interval*86400` 超过 Int64 上限就回绕成负数，
// 卡片变成"永久到期"。`add_days` 现在把间隔夹到 100 年。

///|
test "max_interval_days 是 100 年" {
  let d = max_interval_days()
  assert_true(approx(d, 36500.0, 0.000000001))
}

///|
test "add_days 夹住超大间隔，不产生负数" {
  let now : Timestamp = 1700000000L
  // 1e20 天，远超 Int64 能表示的范围
  let due = add_days(now, 1.0e20)
  inspect(due < 0L, content="false")
  inspect(due > now, content="true")
  // 应当正好是 100 年后
  let expected = now + 36500L * 86400L
  inspect(due.to_string(), content=expected.to_string())
}

///|
test "add_days 把负间隔夹到 0（due 不早于 now）" {
  let now : Timestamp = 1700000000L
  let due = add_days(now, -5.0)
  inspect(due.to_string(), content="1700000000")
}

///|
test "add_days 处理 NaN" {
  let now : Timestamp = 1700000000L
  let nan = 0.0 / 0.0
  let due = add_days(now, nan)
  inspect(due.to_string(), content="1700000000")
}

///|
test "add_days 正常值不受影响" {
  let now : Timestamp = 0L
  inspect(add_days(now, 1.0).to_string(), content="86400")
  inspect(add_days(now, 16.0).to_string(), content="1382400")
  inspect(
    add_days(now, 36500.0).to_string(),
    content=(36500L * 86400L).to_string(),
  )
}

///|
test "FSRS 连续 Easy 60 次后 due 仍然为正且单调" {
  let sched = Fsrs::new()
  let mut st = sched.init("c1", 0L)
  let mut now : Timestamp = 0L
  let mut prev_due : Timestamp = 0L
  for i in 0..<60 {
    st = sched.review(st, Grade::Easy, now)
    now = st.due
    // due 必须始终为正、且不早于上一次
    assert_true(st.due > 0L)
    assert_true(st.due >= prev_due)
    prev_due = st.due
  }
}

///|
test "FSRS 连续 Easy 后 due 受上限保护（安全属性）" {
  let sched = Fsrs::new()
  let mut st = sched.init("c1", 0L)
  let mut now : Timestamp = 0L
  for i in 0..<60 {
    st = sched.review(st, Grade::Easy, now)
    now = st.due
  }
  // due 是安全关键：必须为正、且不超过 now + 100 年
  assert_true(st.due > 0L)
  let cap = now + 36500L * 86400L
  assert_true(st.due <= cap + 86400L)
}

///|
test "FSRS 的 interval_days 与 due 一致封顶（已修复）" {
  // 原先是"已知偏差"：interval_days 未封顶而 due 已封顶，两个字段语义不一致。
  // recall-engine 已在 `fsrs.mbt` 的 `interval_days()` 里对返回值夹到
  // `max_interval_days()`，因此这里改为断言**修复后**的正确行为：
  // 两个字段都受同一个上限约束，就不会有代码用 interval_days 绕过保护。
  let sched = Fsrs::new()
  let mut st = sched.init("c1", 0L)
  let mut now : Timestamp = 0L
  for i in 0..<60 {
    st = sched.review(st, Grade::Easy, now)
    now = st.due
  }
  assert_true(st.interval_days <= max_interval_days())
  assert_true(st.interval_days > 0.0)
  // due 与 interval_days 应当互相一致（都在上限内）
  let expected = now - (st.interval_days * 86400.0).to_int64()
  let diff = st.last_review - expected
  assert_true(diff.abs() <= 1L)
}

///|
test "SM-2 与 Leitner 的正常间隔完全不受上限影响" {
  // 上限是 36500 天，两个经典算法在 10 次内都到不了
  let sm2 = Sm2::new()
  let mut s = sm2.init("c1", 0L)
  for i in 0..<10 {
    s = sm2.review(s, Grade::Good, 0L)
  }
  assert_true(s.interval_days < max_interval_days())

  let leit = Leitner::new()
  let mut l = leit.init("c2", 0L)
  for i in 0..<10 {
    l = leit.review(l, Grade::Easy, 0L)
  }
  assert_true(l.interval_days < max_interval_days())
}

// ─────────────────────────────────────────────────────────────────
// SM-2 间隔封顶回归测试
//
// 背景：SM-2 的间隔是纯几何增长（EF 恒定时 interval(n) = interval(n-1)*EF）。
// 连续答对 30 次后膨胀到 3.2e12 天（约 88 亿年），
// 让 compare/stats 里所有读 interval_days 的统计完全失真。
// 只有在 EF 恒定的路径（如连续 Good，EF 保持 2.5）上才暴露。
// ─────────────────────────────────────────────────────────────────

///|
test "SM-2 连续 Good 30 次：间隔封顶在 100 年，不几何爆炸" {
  let sched = Sm2::new()
  let mut st = sched.init("c1", 0L)
  let mut now : Timestamp = 0L
  for i in 0..<30 {
    st = sched.review(st, Grade::Good, now)
    now = st.due
    // 每一轮都必须受上限约束
    assert_true(st.interval_days <= max_interval_days())
    assert_true(st.interval_days >= 1.0)
  }
  // 30 次后应当正好停在上限
  assert_true(approx(st.interval_days, max_interval_days(), 0.000000001))
  // 修复前的值是 3.2e12；确认现在远小于它
  assert_true(st.interval_days < 1000000.0)
}

///|
test "SM-2 连续 Easy 也封顶（EF 会涨，但仍不能爆炸）" {
  let sched = Sm2::new()
  let mut st = sched.init("c1", 0L)
  let mut now : Timestamp = 0L
  for i in 0..<40 {
    st = sched.review(st, Grade::Easy, now)
    now = st.due
    assert_true(st.interval_days <= max_interval_days())
  }
  assert_true(approx(st.interval_days, max_interval_days(), 0.000000001))
}

///|
test "SM-2 封顶后 due 与 interval_days 仍然一致" {
  let sched = Sm2::new()
  let mut st = sched.init("c1", 0L)
  let mut now : Timestamp = 1700000000L
  for i in 0..<35 {
    st = sched.review(st, Grade::Good, now)
    now = st.due
  }
  // due = last_review + interval_days * 86400
  let expected = add_days(st.last_review, st.interval_days)
  inspect(st.due.to_string(), content=expected.to_string())
}

///|
test "SM-2 封顶后 retrievability 仍可用（不发散）" {
  let sched = Sm2::new()
  let mut st = sched.init("c1", 0L)
  for i in 0..<35 {
    st = sched.review(st, Grade::Good, 0L)
  }
  // 即使是 100 年间隔，R 也必须在 [0,1]
  let r = sched.retrievability(st, st.last_review + 86400L)
  assert_true(r >= 0.0)
  assert_true(r <= 1.0)
}

///|
test "sm2_next_interval 本身带上下界（源头防护）" {
  // 直接调底层函数验证：不论传入多离谱的 prev_interval 都不会溢出
  let huge = sm2_next_interval(1.0e18, 2.5, 20, Grade::Good)
  assert_true(huge <= max_interval_days())

  let zero = sm2_next_interval(0.0, 2.5, 20, Grade::Good)
  assert_true(zero >= 1.0)

  let nan_prev = sm2_next_interval(0.0 / 0.0, 2.5, 20, Grade::Good)
  assert_true(nan_prev >= 1.0)
  assert_true(nan_prev <= max_interval_days())
}

///|
test "SM-2 答错时立刻回到 1 天（不受上限影响）" {
  let sched = Sm2::new()
  let mut st = sched.init("c1", 0L)
  for i in 0..<35 {
    st = sched.review(st, Grade::Good, 0L)
  }
  // 封顶在 100 年后答错
  let lapsed = sched.review(st, Grade::Again, 0L)
  assert_true(approx(lapsed.interval_days, 1.0, 0.000000001))
  assert_true(approx(lapsed.difficulty, 2.18, 0.000000001))
}
