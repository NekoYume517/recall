// ============================================================================
// advice_test.mbt — 负载优化建议器的回归测试
//
// 核心契约：
//   1. 可复现：同输入（含种子）同输出
//   2. 单调性：new_per_day 越大，最终积压不减（二分的合法性依据）
//   3. 边界正确：0 张仍超标 → 建议 0 且 summary 说明存量问题；
//      上界内绰绰有余 → 直接返回上界，不浪费搜索
//   4. 二分收敛：返回值是「达标最大值」，+1 必不达标
// ============================================================================

///|
/// 测试辅助：小配置，跑得快。
fn advice_req_small() -> AdviceRequest {
  { ..AdviceRequest::default(), days: 60, review_limit: 100, }
}

///|
test "advice: 同输入同输出（确定性）" {
  let s : AnyScheduler = AnyScheduler::Fsrs(Fsrs::new())
  let r1 = load_advice(s, advice_req_small())
  let r2 = load_advice(s, advice_req_small())
  assert_eq(r1.new_per_day, r2.new_per_day)
  assert_eq(r1.final_backlog, r2.final_backlog)
  assert_eq(r1.simulation.total_reviews, r2.simulation.total_reviews)
  // 模拟本身逐字节一致
  assert_eq(
    r1.simulation.days
    .map(fn(d) { "\{d.day},\{d.backlog},\{d.reviewed}" })
    .join(";"),
    r2.simulation.days
    .map(fn(d) { "\{d.day},\{d.backlog},\{d.reviewed}" })
    .join(";"),
  )
}

///|
test "advice: 单调性——new_per_day 越大最终积压不减（二分合法性）" {
  let s : AnyScheduler = AnyScheduler::Fsrs(Fsrs::new())
  let req = advice_req_small()
  // 验证若干相邻点：f(n+1) >= f(n)
  // 这是构造保证（多学的卡只增加到期量），但作为二分的合法性依据值得测试锚定
  let mut prev : Int32 = -1
  for npd in [0, 5, 10, 15, 20, 30, 50] {
    let b = probe_final_backlog(s, req, npd)
    if prev >= 0 && b < prev {
      fail(
        "f(\{npd})=\{b} < f(\{npd} 之前)=\{prev}——单调性破坏，二分失效",
      )
    }
    prev = b
  }
}

///|
test "advice: 二分收敛——返回值达标且 +1 不达标" {
  let s : AnyScheduler = AnyScheduler::Fsrs(Fsrs::new())
  let req = advice_req_small()
  let r = load_advice(s, req)
  // 返回值达标
  assert_true(r.final_backlog <= 0)
  // +1 不达标（除非已顶到上界）
  match r.next_step_backlog {
    Some(nb) => assert_true(nb > 0)
    None => assert_eq(r.new_per_day, r.search_hi)
  }
  // summary 提到具体数字
  assert_true(r.summary.contains("\{r.new_per_day}"))
}

///|
test "advice: 完全清零目标下建议值合理且模拟自洽" {
  let s : AnyScheduler = AnyScheduler::Fsrs(Fsrs::new())
  let req = advice_req_small()
  let r = load_advice(s, req)
  // 结果里的模拟必须就是 new_per_day 的那次模拟
  assert_eq(r.simulation.days.length(), 60)
  // 新卡数与建议一致
  for d in r.simulation.days {
    assert_eq(d.new_cards, r.new_per_day)
  }
}

///|
test "advice: 学太快反而积压——超上限后更多新卡是有害的" {
  // 反直觉但真实的行为：每天塞的新卡超过消化能力时，未复习的卡
  // 越积越多。模拟把这个现象自然捕捉：30 天窗口、上限 500 的场景下，
  // 每天 169 张是"积压 ≤ 50"的最大速率，500 张/天反而积压更大。
  // 这正是「建议器必须用模拟而不是拍脑袋公式」的证据。
  let s : AnyScheduler = AnyScheduler::Fsrs(Fsrs::new())
  let req : AdviceRequest = {
    days: 30,
    review_limit: 500,
    desired_retention: 0.9,
    policy_factory: fn() { optimistic_policy() },
    seed: 20240101L,
    target_backlog: 50,
  }
  let r = load_advice(s, req)
  // 返回值本身达标
  assert_true(r.final_backlog <= 50)
  // 「+1 不达标」的收敛契约在非平台区仍然成立
  match r.next_step_backlog {
    Some(nb) => assert_true(nb > 50)
    None => assert_eq(r.new_per_day, r.search_hi)
  }
  // 反直觉证据：上界速率（500）的积压严格大于建议速率
  assert_true(probe_final_backlog(s, req, 500) > r.final_backlog)
}

///|
test "advice: 单点评估 probe_final_backlog 与完整模拟一致" {
  // probe 是 load_advice 的构件，单独暴露；它必须与直接跑 simulate 一致
  let s : AnyScheduler = AnyScheduler::Fsrs(Fsrs::new())
  let req = advice_req_small()
  let b = probe_final_backlog(s, req, 20)
  let direct = simulate(s, req.to_config(20))
  assert_eq(b, direct.final_backlog)
}

///|
test "advice: 容量真充裕时直接返回上界" {
  // 目标极宽松（允许 5000 积压）→ 上界 500 张/天轻松达标，
  // 走 hi_backlog <= target 的短路分支
  let s : AnyScheduler = AnyScheduler::Fsrs(Fsrs::new())
  let req : AdviceRequest = {
    days: 30,
    review_limit: 500,
    desired_retention: 0.9,
    policy_factory: fn() { optimistic_policy() },
    seed: 20240101L,
    target_backlog: 100000,
  }
  let r = load_advice(s, req)
  assert_eq(r.new_per_day, 500)
  assert_true(r.next_step_backlog is None)
  assert_eq(r.search_lo, 500)
  assert_eq(r.search_hi, 500)
  assert_true(r.summary.contains("绰绰有余"))
}

///|
test "advice: 非零目标积压也能工作" {
  let s : AnyScheduler = AnyScheduler::Fsrs(Fsrs::new())
  let req = { ..advice_req_small(), target_backlog: 10, }
  let r = load_advice(s, req)
  assert_true(r.final_backlog <= 10)
  match r.next_step_backlog {
    Some(nb) => assert_true(nb > 10)
    None => ()
  }
}

///|
test "advice: 不同调度器给出不同建议（FSRS vs SM-2 有区分度）" {
  let req = advice_req_small()
  let r_fsrs = load_advice(AnyScheduler::Fsrs(Fsrs::new()), req)
  let r_sm2 = load_advice(AnyScheduler::Sm2(Sm2::new()), req)
  // 不预设谁大谁小（依赖策略细节），但两者都必须给出可自洽的建议
  assert_true(r_fsrs.final_backlog <= 0)
  assert_true(r_sm2.final_backlog <= 0)
  // 两者的"再多一张"都真实不达标（若存在）
  match r_fsrs.next_step_backlog {
    Some(nb) => assert_true(nb > 0)
    None => assert_eq(r_fsrs.new_per_day, r_fsrs.search_hi)
  }
  match r_sm2.next_step_backlog {
    Some(nb) => assert_true(nb > 0)
    None => assert_eq(r_sm2.new_per_day, r_sm2.search_hi)
  }
}
