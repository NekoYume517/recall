// 回归：advice 的搜索路径没把 `AdviceRequest.desired_retention` 施加到
// 调度器实例上——同一份请求，只改这个字段，搜索给出逐字段相同的结果。
//
// 分层约定（RC-3，2026-10-27，simulate_retention_field_regression_test 锁定）：
//   - 泛型 `simulate_with` / `simulate_with_budget` **按传入实例原样跑**；
//   - 配置里的 `desired_retention` 只在 `AnyScheduler` 入口生效，
//     `simulate` 会先重建实例。
//
// `probe_backlog`（→ `simulate`）遵守了这条；`probe_outcome`
// （→ 泛型 `simulate_with_budget`）没有。于是：
//   - `probe_final_backlog(s, req, n)` 用 0.7 反解间隔；
//   - `load_advice_with_budget(s, req, MAX)` 仍按实例默认 0.9 跑；
// 而文档把 `probe_final_backlog` 说成「`load_advice` 的构件」、
// `AdviceRequest::to_config` 每次都填这个字段。RC-3 的原话是
// 「声明为『透传』的字段必须真的影响结果」。

///|
fn advice_retention_request(r : Double) -> AdviceRequest {
  {
    days: 40,
    review_limit: 10,
    desired_retention: r,
    policy_factory: fn() { grade_policy_with_seed("realistic", 20240101L) },
    seed: 20240101L,
    target_backlog: 20,
  }
}

///|
test "advice desired_retention: 只改这个字段，搜索结果必须不同" {
  let s = AnyScheduler::Fsrs(Fsrs::new())
  let ra = load_advice_with_budget(
    s,
    advice_retention_request(0.7),
    9223372036854775807L,
  )
  let a = match ra {
    AdviceCompleted(r) => r
    AdviceAborted(_) => fail("Int64.MAX 预算不该中止")
  }
  let rb = load_advice_with_budget(
    s,
    advice_retention_request(0.9),
    9223372036854775807L,
  )
  let b = match rb {
    AdviceCompleted(r) => r
    AdviceAborted(_) => fail("Int64.MAX 预算不该中止")
  }
  assert_true(
    a.simulation.total_reviews != b.simulation.total_reviews ||
    a.final_backlog != b.final_backlog ||
    a.new_per_day != b.new_per_day,
  )
}

///|
test "advice desired_retention: 与 AnyScheduler 入口的 simulate 逐字段一致" {
  let req = advice_retention_request(0.7)
  let s = AnyScheduler::Fsrs(Fsrs::new())
  let advice = match load_advice_with_budget(s, req, 9223372036854775807L) {
    AdviceCompleted(r) => r
    AdviceAborted(_) => fail("Int64.MAX 预算不该中止")
  }
  let cfg = req.to_config(advice.new_per_day)
  // 配置优先：与 `simulate`（CLI 与 advice 都该服从的语义）逐字段相同。
  let via_config = simulate(s, cfg)
  assert_eq(via_config.total_reviews, advice.simulation.total_reviews)
  assert_eq(via_config.final_backlog, advice.simulation.final_backlog)
  assert_eq(advice.simulation.final_backlog, advice.final_backlog)
  // 「probe_final_backlog 是 load_advice 的构件」：把搜索结果代回去，
  // 必须复现同一个积压。
  let single = probe_final_backlog(s, req, advice.new_per_day)
  assert_eq(single, advice.final_backlog)
}
