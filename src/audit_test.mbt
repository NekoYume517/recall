// 对抗性审查的回归测试（recall-audit）

// 候选 1：Fsrs::with_params 负权重

///|
test "audit: with_params 负权重退回默认" {
  let f = Fsrs::with_params([-1.0, -1.0])
  assert_eq(f.w.length(), 21)
  assert_true(near(f.w[0], 0.40255))
}

// 候选 2：JSONL UTF-8 BOM

///|
test "audit: JSONL BOM 行可解析" {
  let text = "﻿{\"card_id\":\"c1\",\"reviewed_at\":100,\"due_at\":0,\"grade\":3,\"elapsed_days\":1}\n"
  match ReviewLog::from_jsonl(text) {
    Ok(log) => inspect(log.length(), content="1")
    Err(_) => inspect("BOM rejected", content="accepted")
  }
}

// 候选 3：Leitner retrievability 分段线性 vs 初始 1.0

///|
test "audit: Leitner retrievability 初始不高于复习后" {
  let sched = Leitner::new()
  let init_st = sched.init("c1", 0L)
  let r_new = sched.retrievability(init_st, 86400L * 3L)
  let after = sched.review(init_st, Grade::Good, 0L)
  let r_after = sched.retrievability(after, 0L + 86400L * 2L)
  // 初始卡（未复习）不应比刚复习过的卡"记得更牢"
  assert_true(r_after >= r_new)
}

// 候选 4：simultaneous grade 4 → statistics retention

///|
test "audit: Grade::from_int(-2147483648) 是 Again" {
  inspect(Grade::label(Grade::from_int(-2147483648)), content="again")
}

// 候选 5：by_card 稳定排序在负时间戳下

///|
test "audit: by_card 对同一秒多条保持文件顺序（跨卡片）" {
  let log = ReviewLog::new()
  log.push(ReviewEvent::new("x", -100L, 0L, Grade::Good, 0.0))
  log.push(ReviewEvent::new("x", -100L, 0L, Grade::Again, 0.0))
  log.push(ReviewEvent::new("x", -200L, 0L, Grade::Hard, 0.0))
  let groups = log.by_card()
  match groups.get("x") {
    Some(arr) => {
      inspect(arr[0].reviewed_at.to_string(), content="-200")
      inspect(arr[1].reviewed_at.to_string(), content="-100")
      inspect(Grade::label(arr[1].grade), content="good")
      inspect(Grade::label(arr[2].grade), content="again")
    }
    None => inspect("missing x", content="found")
  }
}

// ─────────────────────────────────────────────────────────────────
// 第二轮：JSONL 极端输入（全部通过 → 确认无 bug）
// ─────────────────────────────────────────────────────────────────

///|
test "audit: field_timestamp 拒绝超大时间戳（Int64 溢出防护）" {
  let text = "{\"card_id\":\"c1\",\"reviewed_at\":9000000000000,\"due_at\":0,\"grade\":3,\"elapsed_days\":1}\n"
  match ReviewLog::from_jsonl(text) {
    Ok(_) => inspect("overflow accepted", content="rejected")
    Err(BadTimestamp(_, _)) => inspect("rejected", content="rejected")
    Err(_) => inspect("wrong error", content="BadTimestamp")
  }
}

///|
test "audit: JSONL 负时间戳下界合法（公元 1 年）" {
  let text = "{\"card_id\":\"c1\",\"reviewed_at\":-62135596800,\"due_at\":-62135596800,\"grade\":3,\"elapsed_days\":0}\n"
  match ReviewLog::from_jsonl(text) {
    Ok(log) =>
      inspect(log.events[0].reviewed_at.to_string(), content="-62135596800")
    Err(_) => inspect("rejected", content="accepted")
  }
}

///|
test "audit: grade 2.7 四舍五入为 Good(3)" {
  let text = "{\"card_id\":\"c1\",\"reviewed_at\":100,\"due_at\":0,\"grade\":2.7,\"elapsed_days\":1}\n"
  match ReviewLog::from_jsonl(text) {
    Ok(log) => inspect(Grade::label(log.events[0].grade), content="good")
    Err(_) => inspect("rejected", content="parsed")
  }
}

///|
test "audit: grade -0.4 → Again" {
  let text = "{\"card_id\":\"c1\",\"reviewed_at\":100,\"due_at\":0,\"grade\":-0.4,\"elapsed_days\":1}\n"
  match ReviewLog::from_jsonl(text) {
    Ok(log) => inspect(Grade::label(log.events[0].grade), content="again")
    Err(_) => inspect("rejected", content="parsed")
  }
}

///|
test "audit: JSONL NaN grade 被拒绝" {
  let text = "{\"card_id\":\"c1\",\"reviewed_at\":100,\"due_at\":0,\"grade\":NaN,\"elapsed_days\":1}\n"
  match ReviewLog::from_jsonl(text) {
    Ok(_) => inspect("nan accepted", content="rejected")
    Err(_) => inspect("rejected", content="rejected")
  }
}

///|
test "audit: 重复 card_id+时间戳的两条事件都保留且稳定有序" {
  let text = "{\"card_id\":\"c1\",\"reviewed_at\":100,\"due_at\":0,\"grade\":3,\"elapsed_days\":0}\n{\"card_id\":\"c1\",\"reviewed_at\":100,\"due_at\":0,\"grade\":1,\"elapsed_days\":0}\n"
  match ReviewLog::from_jsonl(text) {
    Ok(log) => {
      inspect(log.length(), content="2")
      let groups = log.by_card()
      match groups.get("c1") {
        Some(arr) => {
          inspect(Grade::label(arr[0].grade), content="good")
          inspect(Grade::label(arr[1].grade), content="hard")
        }
        None => inspect("missing c1", content="found")
      }
    }
    Err(_) => inspect("rejected", content="parsed")
  }
}

// ─────────────────────────────────────────────────────────────────
// 第三轮：算法数值边界
// ─────────────────────────────────────────────────────────────────

///|
test "audit: with_params 21 项权重原样保留" {
  let w = fsrs_default_w()
  w[0] = 0.5
  let f = Fsrs::with_params(w)
  assert_eq(f.w.length(), 21)
  assert_true(near(f.w[0], 0.5))
}

///|
test "audit: with_params 25 项超长权重也接受（不崩溃）" {
  let w = {
    let base = fsrs_default_w()
    base.push(1.0)
    base.push(1.0)
    base.push(1.0)
    base.push(1.0)
    base
  }
  let f = Fsrs::with_params(w)
  assert_true(f.w.length() >= 21)
  let st = f.review(f.init("c", 0L), Grade::Good, 0L)
  assert_true(st.interval_days >= 1.0)
}

///|
test "audit: 全零权重数组不产生 NaN" {
  let zeros = Array::make(21, 0.0)
  let f = Fsrs::with_params(zeros)
  assert_eq(f.w.length(), 21)
  let mut st = f.init("c", 0L)
  let mut now : Timestamp = 0L
  for _i in 0..<10 {
    st = f.review(st, Grade::Good, now)
    now = st.due
    assert_true(st.interval_days >= 1.0)
    assert_true(st.interval_days <= max_interval_days())
    assert_true(!st.interval_days.is_nan())
    assert_true(!st.difficulty.is_nan())
    assert_true(!st.stability.is_nan())
  }
}

///|
test "audit: with_retention 极端值退回 0.9（契约）" {
  assert_true(near(Fsrs::with_retention(0.0).desired_retention, 0.9))
  assert_true(near(Fsrs::with_retention(1.0).desired_retention, 0.9))
  assert_true(near(Fsrs::with_retention(-2.0).desired_retention, 0.9))
  assert_true(near(Fsrs::with_retention(1.5).desired_retention, 0.9))
  assert_true(near(Fsrs::with_retention(0.85).desired_retention, 0.85))
}

///|
test "audit: interval_days 在极端输入下仍返回安全正值" {
  assert_true(interval_days(10.0, 0.0) >= 1.0)
  assert_true(interval_days(10.0, 1.0) >= 1.0)
  assert_true(interval_days(10.0, 0.4999) >= 1.0)
  assert_true(interval_days(10.0, 0.9999) >= 1.0)
  assert_true(interval_days(1.0e18, 0.9) <= max_interval_days())
  assert_true(!interval_days(1.0e18, 0.9).is_nan())
}

///|
test "audit: FSRS 提前复习（未到期）不产生垃圾间隔" {
  let f = Fsrs::new()
  let st1 = f.review(f.init("c1", 0L), Grade::Good, 0L)
  let early = st1.due - 2L * 86400L
  assert_true(early > 0L)
  let st2 = f.review(st1, Grade::Good, early)
  assert_true(st2.interval_days >= 1.0)
  assert_true(st2.due > early)
  assert_true(!st2.stability.is_nan())
}

///|
test "audit: 同一时刻重复复习保持安全" {
  let f = Fsrs::new()
  let mut st = f.init("c1", 100L)
  for _i in 0..<8 {
    st = f.review(st, Grade::Good, 100L)
    assert_true(st.interval_days >= 1.0)
    assert_true(st.due >= 100L)
    assert_true(!st.stability.is_nan())
  }
}

///|
test "audit: SM-2 提前复习也不产生垃圾间隔" {
  let s = Sm2::new()
  let st1 = s.review(s.init("c1", 0L), Grade::Good, 0L)
  let st2 = s.review(st1, Grade::Good, st1.due - 86400L)
  assert_true(st2.interval_days >= 1.0)
  assert_true(st2.due > st1.due - 86400L)
}

///|
test "audit: simulate 90 天基准仍可复现（乐观策略零积压）" {
  let cfg : SimConfig = {
    days: 90,
    new_per_day: 20,
    review_limit: 200,
    desired_retention: 0.9,
    grade_fn: optimistic_policy(),
    seed: 1L,
  }
  let res = simulate(AnyScheduler::by_name("fsrs"), cfg)
  assert_eq(res.final_backlog, 0)
  assert_true(res.total_reviews > 0)
}

// ─────────────────────────────────────────────────────────────────
// 第四轮：add_days 的 Int64 上限回绕（真实 bug）
//
// JSONL 合法时间戳最大到 253402300799（9999-12-31）。在该时刻
// `now + interval*86400` 一旦超过 Int64 上限就回绕成负数——
// 卡片变成"永久到期"，与 implementation.md 第 7 节修过的 bug 同根。
// interval_days 已封顶 36500 天，叠加 2.53e11 秒的 now 距溢出仍有
// 余量；真正能触发回绕的是外部构造的越界状态。此测试锁死
// add_days 在 Int64 域的输出永远不回绕成负数。
// ─────────────────────────────────────────────────────────────────

///|
test "audit: add_days 在极大 now 下 due 永远为正（不回绕）" {
  let max_ts : Timestamp = 253402300799L
  let due = add_days(max_ts, max_interval_days())
  assert_true(due > 0L)
  assert_true(due >= max_ts)
}

///|
test "audit: add_days 极大天数与极大 now 叠加不产生负数" {
  let max_ts : Timestamp = 9223372036854775807L / 2L
  let due = add_days(max_ts, 36500.0)
  assert_true(due > 0L)
  assert_true(due >= max_ts)
}

///|
test "audit: FSRS 在最大合法时间戳连续 Easy 后 due 仍为正" {
  let f = Fsrs::new()
  let mut st = f.init("c1", 253402300799L)
  for _i in 0..<60 {
    st = f.review(st, Grade::Easy, 253402300799L)
    assert_true(st.due > 0L)
  }
}

///|
test "audit: SM-2 在最大合法时间戳封顶后 due 仍为正" {
  let s = Sm2::new()
  let mut st = s.init("c1", 253402300799L)
  let mut now : Timestamp = 253402300799L
  for _i in 0..<40 {
    st = s.review(st, Grade::Good, now)
    now = st.due
    assert_true(st.due > 0L)
  }
}
