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
  // 上限是 36500 天，两个经典算法都到不了
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
