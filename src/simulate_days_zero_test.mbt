// 断言补强（2026-11-21 审计，#10）：`--days 0` 的口径。
//
// CLI usage 写明「simulate 允许 0 = 空结果」，`cmd_advice` 则显式拒绝
// 「`--days` 必须为正」。两条都是可断言的公开行为，但此前只有文本、
// 没有测试：库层 `simulate(days=0)` 与 CLI 的 exit 0 都没有锁。
//
// 这里钉住库层这一半：0 天窗口 → 0 天数据、三个计数全 0，不创建新卡。

///|
test "simulate days=0: 空结果且计数全零" {
  let cfg : SimConfig = {
    days: 0,
    new_per_day: 20,
    review_limit: 200,
    desired_retention: 0.9,
    grade_fn: grade_policy_with_seed("realistic", 20240101L),
    seed: 20240101L,
  }
  for
    s in [
      AnyScheduler::Sm2(Sm2::new()),
      AnyScheduler::Fsrs(Fsrs::new()),
      AnyScheduler::Leitner(Leitner::new()),
    ] {
    let r = simulate(s, cfg)
    assert_eq(r.days.length(), 0)
    assert_eq(r.total_reviews, 0)
    assert_eq(r.max_backlog, 0)
    assert_eq(r.final_backlog, 0)
  }
}

///|
test "simulate days=0: 与带预算入口逐字段一致（第 0 天不创建任何卡）" {
  let cfg : SimConfig = {
    days: 0,
    new_per_day: 20,
    review_limit: 200,
    desired_retention: 0.9,
    grade_fn: grade_policy_with_seed("realistic", 20240101L),
    seed: 20240101L,
  }
  let s = AnyScheduler::Fsrs(Fsrs::new())
  let a = simulate(s, cfg)
  let b = match
    simulate_with_budget(
      AnyScheduler::with_config(s, cfg),
      cfg,
      9223372036854775807L,
    ) {
    Completed(r) => r
    Aborted(_) => fail("0 天窗口不该撞预算")
  }
  assert_eq(a.days.length(), b.days.length())
  assert_eq(a.total_reviews, b.total_reviews)
  assert_eq(a.final_backlog, b.final_backlog)
}
