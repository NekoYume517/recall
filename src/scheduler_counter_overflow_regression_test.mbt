// 回归：pub(all) CardState 的计数器抵达 Int32.MAX 后，复习不能回绕成负数。
//
// API.md §1/§3 把 FSRS/Leitner reps 定义为累计成功次数、SM-2 reps 定义为
// 连续成功次数，lapses 则是三调度器一致的累计遗忘次数。直接执行 `+ 1`
// 会让 2147483647 变成 -2147483648，破坏计数语义并导出负统计。

///|
fn maxed_counter_state() -> CardState {
  {
    ..CardState::new("counter", 0L),
    stability: 3.0,
    difficulty: 5.0,
    reps: 2147483647,
    lapses: 2147483647,
    due: 0L,
    interval_days: 3.0,
    phase: Phase::Review,
  }
}

///|
fn assert_counter_review_saturates(s : AnyScheduler) -> Unit raise {
  let success = s.review(maxed_counter_state(), Grade::Good, 86400L)
  assert_eq(success.reps, 2147483647)
  assert_eq(success.lapses, 2147483647)
  let lapse = s.review(maxed_counter_state(), Grade::Again, 86400L)
  assert_eq(lapse.lapses, 2147483647)
  assert_true(lapse.reps >= 0)
}

///|
test "scheduler counters: FSRS 的 reps/lapses 在 Int32.MAX 饱和" {
  assert_counter_review_saturates(AnyScheduler::Fsrs(Fsrs::new()))
}

///|
test "scheduler counters: SM-2 的 reps/lapses 在 Int32.MAX 饱和" {
  assert_counter_review_saturates(AnyScheduler::Sm2(Sm2::new()))
}

///|
test "scheduler counters: Leitner 的 reps/lapses 在 Int32.MAX 饱和" {
  assert_counter_review_saturates(AnyScheduler::Leitner(Leitner::new()))
}

///|
test "scheduler counters: MAX-1 仍正常递增到 MAX" {
  let state = { ..maxed_counter_state(), reps: 2147483646, lapses: 2147483646, }
  for
    s in [
      AnyScheduler::Fsrs(Fsrs::new()),
      AnyScheduler::Sm2(Sm2::new()),
      AnyScheduler::Leitner(Leitner::new()),
    ] {
    assert_eq(s.review(state, Grade::Good, 86400L).reps, 2147483647)
    assert_eq(s.review(state, Grade::Again, 86400L).lapses, 2147483647)
  }
}
