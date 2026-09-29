// leitner.mbt 白盒测试
//
// 覆盖：5 盒 / 间隔 [1,2,4,8,16]、答对进盒、答错回盒 1、到顶封顶、
// 状态字段推进、retrievability 分段线性。
//
// 共享辅助函数 `approx` 在 test_helpers_test.mbt。

test "new 是 5 盒 1/2/4/8/16" {
  let l = Leitner::new()
  inspect(l.boxes, content="5")
  inspect(l.intervals.length(), content="5")
  assert_true(approx(l.intervals[0], 1.0, 0.000000001))
  assert_true(approx(l.intervals[1], 2.0, 0.000000001))
  assert_true(approx(l.intervals[2], 4.0, 0.000000001))
  assert_true(approx(l.intervals[3], 8.0, 0.000000001))
  assert_true(approx(l.intervals[4], 16.0, 0.000000001))
}

test "name 是 leitner" {
  inspect(Leitner::new().name(), content="leitner")
}

test "init 是新卡在盒 1" {
  let sched = Leitner::new()
  let st = sched.init("c1", 1000L)
  inspect(st.card_id, content="c1")
  inspect(st.reps, content="0")
  inspect(st.lapses, content="0")
  inspect(st.due.to_string(), content="1000")
  // 盒 1 的间隔是 1 天
  assert_true(approx(st.interval_days, 1.0, 0.000000001))
  // 盒号存在 difficulty 里
  assert_true(approx(st.difficulty, 1.0, 0.000000001))
  inspect(Phase::label(st.phase), content="新卡")
}

// ─────────────────────────────────────────────────────────────────
// 答对进下一盒：间隔应走 1 → 2 → 4 → 8 → 16 → 16（封顶）
// ─────────────────────────────────────────────────────────────────

test "连续 Good 走完 5 盒：1,2,4,8,16 然后封顶" {
  let sched = Leitner::new()
  let mut state = sched.init("c1", 0L)
  let mut now : Timestamp = 0L
  let expected : Array[Double] = [2.0, 4.0, 8.0, 16.0, 16.0, 16.0]
  // 初始在盒 1（间隔 1），第一次 Good → 盒 2（间隔 2）
  for e in expected {
    state = sched.review(state, Grade::Good, now)
    now = state.due
    let got = state.interval_days
    assert_true(approx(got, e, 0.000000001))
  }
}

test "盒号随 Good 递增并在 5 封顶" {
  let sched = Leitner::new()
  let mut state = sched.init("c1", 0L)
  let mut now : Timestamp = 0L
  // 从盒 1 开始
  assert_true(approx(state.difficulty, 1.0, 0.000000001))
  for i in 0..<8 {
    state = sched.review(state, Grade::Good, now)
    now = state.due
  }
  // 8 次之后早就到顶
  assert_true(approx(state.difficulty, 5.0, 0.000000001))
  assert_true(approx(state.interval_days, 16.0, 0.000000001))
}

test "Easy 也算答对（进盒）" {
  let sched = Leitner::new()
  let st = sched.init("c1", 0L)
  let next = sched.review(st, Grade::Easy, 0L)
  assert_true(approx(next.difficulty, 2.0, 0.000000001))
  assert_true(approx(next.interval_days, 2.0, 0.000000001))
}

// ─────────────────────────────────────────────────────────────────
// 答错回盒 1
// ─────────────────────────────────────────────────────────────────

test "Again 回到盒 1" {
  let sched = Leitner::new()
  let mut state = sched.init("c1", 0L)
  // 先推进到盒 4
  for i in 0..<3 {
    state = sched.review(state, Grade::Good, 0L)
  }
  assert_true(approx(state.difficulty, 4.0, 0.000000001))
  assert_true(approx(state.interval_days, 8.0, 0.000000001))
  // 答错 → 盒 1，间隔 1
  state = sched.review(state, Grade::Again, 0L)
  assert_true(approx(state.difficulty, 1.0, 0.000000001))
  assert_true(approx(state.interval_days, 1.0, 0.000000001))
}

test "Hard 也算答对（进盒），与 SM-2 判定一致" {
  let sched = Leitner::new()
  let mut state = sched.init("c1", 0L)
  // 推进到盒 3
  for i in 0..<2 {
    state = sched.review(state, Grade::Good, 0L)
  }
  assert_true(approx(state.difficulty, 3.0, 0.000000001))
  // Hard：is_recalled 为 true → 进盒 4
  state = sched.review(state, Grade::Hard, 0L)
  assert_true(approx(state.difficulty, 4.0, 0.000000001))
  assert_true(approx(state.interval_days, 8.0, 0.000000001))
  // 与 SM-2 一致：Hard 都算答对
  inspect(sm2_is_correct(Grade::Hard), content="true")
  inspect(is_recalled(Grade::Hard), content="true")
}

test "答错后能重新往上爬" {
  let sched = Leitner::new()
  let mut state = sched.init("c1", 0L)
  state = sched.review(state, Grade::Good, 0L)
  state = sched.review(state, Grade::Good, 0L)
  state = sched.review(state, Grade::Again, 0L)
  // 回盒 1
  assert_true(approx(state.difficulty, 1.0, 0.000000001))
  // 再答对 → 盒 2
  state = sched.review(state, Grade::Good, 0L)
  assert_true(approx(state.difficulty, 2.0, 0.000000001))
  assert_true(approx(state.interval_days, 2.0, 0.000000001))
}

// ─────────────────────────────────────────────────────────────────
// 计数与阶段
// ─────────────────────────────────────────────────────────────────

test "lapses 只在答错时增加" {
  let sched = Leitner::new()
  let mut state = sched.init("c1", 0L)
  state = sched.review(state, Grade::Good, 0L)
  inspect(state.lapses, content="0")
  state = sched.review(state, Grade::Again, 0L)
  inspect(state.lapses, content="1")
  state = sched.review(state, Grade::Again, 0L)
  inspect(state.lapses, content="2")
}

test "reps 只在答对时累加" {
  let sched = Leitner::new()
  let mut state = sched.init("c1", 0L)
  state = sched.review(state, Grade::Good, 0L)
  inspect(state.reps, content="1")
  state = sched.review(state, Grade::Again, 0L)
  // 答错不减 reps（与 SM-2 不同）
  inspect(state.reps, content="1")
  state = sched.review(state, Grade::Good, 0L)
  inspect(state.reps, content="2")
}

test "phase: 盒 <3 是 Learning，>=3 是 Review" {
  let sched = Leitner::new()
  let mut state = sched.init("c1", 0L)
  // 盒 2
  state = sched.review(state, Grade::Good, 0L)
  inspect(Phase::label(state.phase), content="学习中")
  // 盒 3
  state = sched.review(state, Grade::Good, 0L)
  inspect(Phase::label(state.phase), content="复习")
}

test "phase: 从未复习就答错仍是 Learning，复习过后答错是 Relearning" {
  let sched = Leitner::new()
  // 新卡直接答错
  let fresh = sched.init("c1", 0L)
  let l1 = sched.review(fresh, Grade::Again, 0L)
  inspect(Phase::label(l1.phase), content="学习中")
  // 复习过再答错
  let reviewed = sched.review(fresh, Grade::Good, 0L)
  let l2 = sched.review(reviewed, Grade::Again, 0L)
  inspect(Phase::label(l2.phase), content="重学")
}

test "due 按盒间隔推进" {
  let sched = Leitner::new()
  let st = sched.init("c1", 0L)
  // 盒 1 → 盒 2，间隔 2 天
  let s1 = sched.review(st, Grade::Good, 0L)
  inspect(s1.due.to_string(), content="172800")
  // 盒 2 → 盒 3，间隔 4 天，从 s1.due 起算
  let s2 = sched.review(s1, Grade::Good, s1.due)
  inspect(s2.due.to_string(), content="518400")
}

test "review 不修改入参" {
  let sched = Leitner::new()
  let st = sched.init("c1", 0L)
  let _ = sched.review(st, Grade::Good, 0L)
  assert_true(approx(st.difficulty, 1.0, 0.000000001))
  assert_true(approx(st.interval_days, 1.0, 0.000000001))
}

// ─────────────────────────────────────────────────────────────────
// 自定义盒数与间隔表
// ─────────────────────────────────────────────────────────────────

test "with_boxes 生成 2 的幂间隔表" {
  let l = Leitner::with_boxes(3)
  inspect(l.boxes, content="3")
  inspect(l.intervals.length(), content="3")
  assert_true(approx(l.intervals[0], 1.0, 0.000000001))
  assert_true(approx(l.intervals[1], 2.0, 0.000000001))
  assert_true(approx(l.intervals[2], 4.0, 0.000000001))
}

test "with_boxes 夹到 1..20" {
  inspect(Leitner::with_boxes(0).boxes, content="1")
  inspect(Leitner::with_boxes(-5).boxes, content="1")
  inspect(Leitner::with_boxes(999).boxes, content="20")
}

test "3 盒的调度器在盒 3 封顶" {
  let sched = Leitner::with_boxes(3)
  let mut state = sched.init("c1", 0L)
  for i in 0..<6 {
    state = sched.review(state, Grade::Good, 0L)
  }
  assert_true(approx(state.difficulty, 3.0, 0.000000001))
  assert_true(approx(state.interval_days, 4.0, 0.000000001))
}

// ─────────────────────────────────────────────────────────────────
// retrievability（基线约定值）
// ─────────────────────────────────────────────────────────────────

test "retrievability 未到期恒为 1" {
  let sched = Leitner::new()
  let st = sched.init("c1", 0L) // due = 0，间隔 1 天
  // 到期前
  let r = sched.retrievability(st, -1000L)
  assert_true(approx(r, 1.0, 0.000000001))
  // 到期时刻本身
  let r2 = sched.retrievability(st, 0L)
  assert_true(approx(r2, 1.0, 0.000000001))
}

test "retrievability 逾期后线性衰减" {
  let sched = Leitner::new()
  let st = sched.init("c1", 0L) // due = 0，间隔 1 天 = 86400 秒
  // 逾期半天 → 1 - 0.5 = 0.5
  let r = sched.retrievability(st, 43200L)
  assert_true(approx(r, 0.5, 0.000001))
  // 逾期一整个间隔 → 0
  let r2 = sched.retrievability(st, 86400L)
  assert_true(approx(r2, 0.0, 0.000001))
}

test "retrievability 单调下降且夹在 [0,1]" {
  let sched = Leitner::new()
  let st = sched.init("c1", 0L)
  let mut prev = 1.1
  for d in [0, 0, 1, 2, 5, 100] {
    let now : Timestamp = Int::to_int64(d) * 86400L
    let r = sched.retrievability(st, now)
    assert_true(r <= prev)
    assert_true(r >= 0.0)
    assert_true(r <= 1.0)
    prev = r
  }
}

test "desired_retention 固定 1.0" {
  let r = Leitner::new().desired_retention()
  assert_true(approx(r, 1.0, 0.000000001))
}

// ─────────────────────────────────────────────────────────────────
// 跨调度器：Leitner 的间隔增长慢于 SM-2（对照基线的意义）
// ─────────────────────────────────────────────────────────────────

test "同样 Good x5，Leitner 的最终间隔远小于 SM-2" {
  let sm2 = Sm2::new()
  let leit = Leitner::new()
  let mut s_sm2 = sm2.init("c1", 0L)
  let mut s_leit = leit.init("c1", 0L)
  for i in 0..<5 {
    s_sm2 = sm2.review(s_sm2, Grade::Good, 0L)
    s_leit = leit.review(s_leit, Grade::Good, 0L)
  }
  // SM-2 是 95 天，Leitner 封顶 16 天
  assert_true(approx(s_sm2.interval_days, 95.0, 0.000000001))
  assert_true(approx(s_leit.interval_days, 16.0, 0.000000001))
  assert_true(s_leit.interval_days < s_sm2.interval_days)
}

test "三个调度器都能通过同一 trait 调用（AnyScheduler 分发）" {
  let st = CardState::new("c1", 0L)
  for name in ["sm2", "fsrs", "leitner"] {
    let s = AnyScheduler::by_name(name)
    let named = Scheduler::name(s)
    inspect(named, content=name)
    let after = Scheduler::review(s, st, Grade::Good, 0L)
    inspect(after.card_id, content="c1")
    assert_true(after.interval_days >= 1.0)
  }
}

test "scheduler_name_valid 与 by_name 一致" {
  inspect(scheduler_name_valid("sm2"), content="true")
  inspect(scheduler_name_valid("fsrs"), content="true")
  inspect(scheduler_name_valid("leitner"), content="true")
  inspect(scheduler_name_valid("SM2"), content="false")
  inspect(scheduler_name_valid("nope"), content="false")
  // 未知名字退回 leitner（不抛错）
  inspect(Scheduler::name(AnyScheduler::by_name("nope")), content="leitner")
}
