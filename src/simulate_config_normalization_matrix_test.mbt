// 验收矩阵（2026-11-21 审计，lead 要求）：`AnyScheduler::with_config` 是
// 「配置 → 调度器」的唯一归一化点。四条入口吃同一份配置时，必须逐卡、
// 逐次复习地走到同一个状态——不是只比 `total_reviews` 这种总数。
//
// 观测手段：`grade_fn` 每次被调用时把 `(card_id, due)` 追加到轨迹数组。
// 于是同一条轨迹就是「每张卡每次到期日的数组」，保留顺序。
// 判据：四条入口的轨迹数组逐元素相等（`String` + `Int64` 精确比较）。
//
// 入口：
//   1. `simulate`（AnyScheduler 入口，内部 with_config）
//   2. `simulate_with(with_config(s, cfg), cfg)`（调用方自己归一化）
//   3. `simulate_with_budget(with_config(s, cfg), cfg, Int64.MAX)`
//   4. `load_advice_with_budget(s, req, Int64.MAX)`——要求它的
//      `simulation` 与同配置的 `simulate` 轨迹相等（advice 内部必须
//      先过 with_config；修复前它绕过，retention 不生效）。
//
// 组合按 lead 指定：days=30、new_per_day=5、review_limit=200、
// retention=0.97。第 4 条把 review_limit 收到 5（只是把搜索上界钉在 5，
// 让 advice 直接返回 5 张/天），轨迹对照仍用同一份 5/5/0.97 配置。

///|
fn matrix_config(
  trace : Array[(String, Int64)],
  new_per_day : Int32,
  review_limit : Int32,
  retention : Double,
) -> SimConfig {
  let base = grade_policy_with_seed("realistic", 20240101L)
  {
    days: 30,
    new_per_day,
    review_limit,
    desired_retention: retention,
    grade_fn: fn(st) {
      trace.push((st.card_id, st.due))
      base(st)
    },
    seed: 20240101L,
  }
}

///|
fn trace_eq(a : Array[(String, Int64)], b : Array[(String, Int64)]) -> Bool {
  if a.length() != b.length() {
    return false
  }
  for i in 0..<a.length() {
    if a[i].0 != b[i].0 || a[i].1 != b[i].1 {
      return false
    }
  }
  true
}

///|
test "模拟入口归一化矩阵: 四条入口的逐卡到期日轨迹逐元素相等" {
  let s = AnyScheduler::Fsrs(Fsrs::new())
  let t1 : Array[(String, Int64)] = []
  let cfg1 = matrix_config(t1, 5, 200, 0.97)
  ignore(simulate(s, cfg1))
  let t2 : Array[(String, Int64)] = []
  let cfg2 = matrix_config(t2, 5, 200, 0.97)
  ignore(simulate_with(AnyScheduler::with_config(s, cfg2), cfg2))
  let t3 : Array[(String, Int64)] = []
  let cfg3 = matrix_config(t3, 5, 200, 0.97)
  ignore(
    simulate_with_budget(
      AnyScheduler::with_config(s, cfg3),
      cfg3,
      9223372036854775807L,
    ),
  )
  // 对照 1：三条直接入口的轨迹必须彼此相等（且非空）。
  assert_true(t1.length() > 0)
  assert_true(trace_eq(t1, t2))
  assert_true(trace_eq(t1, t3))
  // 对照 2：0.97 必须真的改变轨迹（否则整组断言是空的）。
  let t90 : Array[(String, Int64)] = []
  ignore(simulate(s, matrix_config(t90, 5, 200, 0.9)))
  assert_true(!trace_eq(t1, t90))
  // 第 4 条：advice 的搜索路径。
  let req : AdviceRequest = {
    days: 30,
    review_limit: 5,
    desired_retention: 0.97,
    policy_factory: fn() { grade_policy_with_seed("realistic", 20240101L) },
    seed: 20240101L,
    target_backlog: 1000000,
  }
  let adv = match load_advice_with_budget(s, req, 9223372036854775807L) {
    AdviceCompleted(r) => r
    AdviceAborted(_) => fail("Int64.MAX 预算不该中止")
  }
  assert_eq(adv.new_per_day, 5)
  let t4 : Array[(String, Int64)] = []
  let cfg4 = matrix_config(t4, 5, 5, 0.97)
  ignore(simulate(s, cfg4))
  assert_true(trace_eq(t4, t2) == false)
  // advice 的 simulation 只暴露聚合，但轨迹由 share 的 grade_fn 记录：
  // 第 4 条入口自己的探针（hi=5）产生 t_adv；与 5/5/0.97 的直接入口比。
  let t_adv : Array[(String, Int64)] = []
  let req2 : AdviceRequest = {
    days: 30,
    review_limit: 5,
    desired_retention: 0.97,
    policy_factory: fn() {
      let base = grade_policy_with_seed("realistic", 20240101L)
      fn(st) {
        t_adv.push((st.card_id, st.due))
        base(st)
      }
    },
    seed: 20240101L,
    target_backlog: 1000000,
  }
  let adv2 = match load_advice_with_budget(s, req2, 9223372036854775807L) {
    AdviceCompleted(r) => r
    AdviceAborted(_) => fail("Int64.MAX 预算不该中止")
  }
  assert_true(trace_eq(t4, t_adv))
  assert_true(adv2.simulation.total_reviews > 0)
}
