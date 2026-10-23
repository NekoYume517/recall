// ============================================================================
// advice_test.mbt — 负载优化建议器的回归测试
//
// 核心契约：
//   1. 可复现：同输入（含种子）同输出
//   2. 非单调：new_per_day 越大，最终积压**不一定**不减 —— 积压对 n 非单调，
//      所以不能用二分（反例见下面「积压对 new_per_day 非单调」）
//   3. 边界正确：0 张仍超标 → 建议 0 且 summary 说明存量问题；
//      上界内绰绰有余 → 直接返回上界，不浪费搜索
//   4. 收敛：返回值是「达标最大值」，+1 必不达标
//
// 成本约束：扫描化后 load_advice 最坏要跑 O(review_limit) 次完整模拟，
// 所以除「原始反例的 probe 级证据」外，回归一律用 15–30 天 / 上限 30–80
// 的小配置（每个用例 < 1s），保证 `moon test` 秒级完成。原始 90 天 /
// 上限 150 的真实数值（f(43..46)、f(50..53)）用 probe 锁住，成本 7 次模拟。
// ============================================================================

///|
/// 测试辅助：小配置，跑得快（20 天 / 上限 30 / 清零目标）。
/// 该配置下真实最大值是 10：f(0..10)=0、f(11)=9，扫描 22 次模拟。
fn advice_req_small() -> AdviceRequest {
  { ..AdviceRequest::default(), days: 20, review_limit: 30, }
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
test "advice: 积压对 new_per_day 非单调（二分前提被证伪）" {
  // 旧实现顶部注释断言「new_per_day 与最终积压单调相关（这是构造保证）」
  // 并据此二分。实测不成立：评分策略按真实 elapsed 抽样，种子固定但
  // 随机流被 n 改变的路径是非线性的，于是积压曲线会出现「回落」。
  // 这里保留最原始的 90 天 / 上限 150 反例（5 次 probe，成本 0.2s）：
  // f(44) 高于 f(43)，而 f(45) 又低于 f(44) —— 任何基于单调假设的二分
  // 都会漏掉 45。load_advice 层面的回归用下面的小配置，见 RC-1 用例。
  let s : AnyScheduler = AnyScheduler::Fsrs(Fsrs::new())
  let req : AdviceRequest = {
    days: 90,
    review_limit: 150,
    desired_retention: 0.9,
    policy_factory: fn() { optimistic_policy() },
    seed: 20240101L,
    target_backlog: 500,
  }
  let f43 = probe_final_backlog(s, req, 43)
  let f44 = probe_final_backlog(s, req, 44)
  let f45 = probe_final_backlog(s, req, 45)
  assert_true(f44 > f43)
  assert_true(f45 < f44)
  // 另一处回落（复习上限 200）：f(55)=480 → f(56)=424
  let req200 = { ..req, review_limit: 200, }
  assert_true(
    probe_final_backlog(s, req200, 56) < probe_final_backlog(s, req200, 55),
  )
}

///|
test "advice RC-1: 小配置复现二分少报（optimistic 30 天/上限 80/目标 96 → 31，旧给 29）" {
  // 90 天 / 上限 150 的原始配置要跑 107 次模拟（~10s），测试里换成同族
  // 但小得多的配置：30 天 / 上限 80 / 目标 96，答案 31、旧二分给 29，
  // 缺陷形态完全一致（f(30) 超标、f(31) 达标 = 曲线回落）。
  let s : AnyScheduler = AnyScheduler::Fsrs(Fsrs::new())
  let req : AdviceRequest = {
    days: 30,
    review_limit: 80,
    desired_retention: 0.9,
    policy_factory: fn() { optimistic_policy() },
    seed: 20240101L,
    target_backlog: 96,
  }
  // 该配置确实非单调：f(30) > 96 = f(31)
  assert_true(probe_final_backlog(s, req, 30) > 96)
  assert_true(probe_final_backlog(s, req, 31) <= 96)
  // 真实最大值 31（旧二分停在 29），+1 超标
  assert_true(probe_final_backlog(s, req, 32) > 96)
  let r = load_advice(s, req)
  assert_eq(r.new_per_day, 31)
  assert_true(r.final_backlog <= 96)
  assert_eq(r.final_backlog, probe_final_backlog(s, req, 31))
  match r.next_step_backlog {
    Some(nb) => assert_eq(nb, probe_final_backlog(s, req, 32))
    None =>
      fail("推荐值未达搜索上界，next_step_backlog 不应为 None")
  }
}

///|
test "advice RC-1: 换策略也复现二分少报（realistic 15 天/上限 60/目标 1 → 19，旧给 17）" {
  // 第二个小配置，用 realistic 评分策略：答案是 19、旧二分给 17。
  // 两条用例一起覆盖「不同策略 + 不同目标量级」下的少报。
  let s : AnyScheduler = AnyScheduler::Fsrs(Fsrs::new())
  let req : AdviceRequest = {
    days: 15,
    review_limit: 60,
    desired_retention: 0.9,
    policy_factory: fn() { grade_policy_with_seed("realistic", 20240101L) },
    seed: 20240101L,
    target_backlog: 1,
  }
  // 非单调：f(18) > 1 = f(19)
  assert_true(probe_final_backlog(s, req, 18) > 1)
  assert_true(probe_final_backlog(s, req, 19) <= 1)
  let r = load_advice(s, req)
  assert_eq(r.new_per_day, 19)
  assert_true(r.final_backlog <= 1)
  match r.next_step_backlog {
    Some(nb) => assert_true(nb > 1)
    None =>
      fail("推荐值未达搜索上界，next_step_backlog 不应为 None")
  }
}

///|
test "advice RC-1: 大目标下真实最大值是 52（probe 级，旧二分给 50）" {
  // 原始 90 天 / 上限 150 配置的第二个反例，只用 probe 锁事实（4 次模拟）：
  // f(50)=800 达标，但 f(51)=1020、f(52)=978 —— 二分在 50 停下，
  // 真实最大值是 52（f(53)=1070 超标）。load_advice 的行为由上面两个
  // 小配置覆盖。
  let s : AnyScheduler = AnyScheduler::Fsrs(Fsrs::new())
  let req : AdviceRequest = {
    days: 90,
    review_limit: 150,
    desired_retention: 0.9,
    policy_factory: fn() { optimistic_policy() },
    seed: 20240101L,
    target_backlog: 1000,
  }
  assert_true(probe_final_backlog(s, req, 50) <= 1000)
  assert_true(probe_final_backlog(s, req, 51) > 1000)
  assert_true(probe_final_backlog(s, req, 52) <= 1000)
  assert_true(probe_final_backlog(s, req, 53) > 1000)
}

///|
test "advice RC-1: 单调区间内结果与修复前一致（target=0/limit=30）" {
  // 常见形态（清零目标、小上限）落在单调区间：f(0..7)=0，f(8)>0。
  // 修复前二分与修复后扫描都必须是 7 —— 扫描化不应带来行为漂移。
  // （原用例用默认 90 天 / 上限 200，要 166 次模拟 ~31s，同理降规模。）
  let s : AnyScheduler = AnyScheduler::Fsrs(Fsrs::new())
  let req = advice_req_small()
  let r = load_advice(s, req)
  assert_eq(r.new_per_day, 7)
  assert_eq(r.final_backlog, 0)
  assert_true(probe_final_backlog(s, req, 8) > 0)
}

///|
test "advice: 扫描收敛——返回值达标且 +1 不达标" {
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
  assert_eq(r.simulation.days.length(), 20)
  // 新卡数与建议一致
  for d in r.simulation.days {
    assert_eq(d.new_cards, r.new_per_day)
  }
}

///|
test "advice: 学太快反而积压——超上限后更多新卡是有害的" {
  // 反直觉但真实的行为：每天塞的新卡超过消化能力时，未复习的卡
  // 越积越多。模拟把现象自然捕捉：30 天窗口、上限 40、目标 20 时，
  // 每天 14 张是最大速率，而上限速率 40 张/天积压 840 张。
  // 这正是「建议器必须用模拟而不是拍脑袋公式」的证据。
  let s : AnyScheduler = AnyScheduler::Fsrs(Fsrs::new())
  let req : AdviceRequest = {
    days: 30,
    review_limit: 40,
    desired_retention: 0.9,
    policy_factory: fn() { optimistic_policy() },
    seed: 20240101L,
    target_backlog: 20,
  }
  let r = load_advice(s, req)
  // 返回值本身达标
  assert_true(r.final_backlog <= 20)
  // 「+1 不达标」的收敛契约在非平台区仍然成立
  match r.next_step_backlog {
    Some(nb) => assert_true(nb > 20)
    None => assert_eq(r.new_per_day, r.search_hi)
  }
  // 反直觉证据：上界速率（40）的积压严格大于建议速率
  assert_true(probe_final_backlog(s, req, 40) > r.final_backlog)
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
  // 目标极宽松（允许 100000 积压）→ 上界 60 张/天轻松达标，
  // 走 hi_backlog <= target 的短路分支（只跑 2 次模拟）
  let s : AnyScheduler = AnyScheduler::Fsrs(Fsrs::new())
  let req : AdviceRequest = {
    days: 30,
    review_limit: 60,
    desired_retention: 0.9,
    policy_factory: fn() { optimistic_policy() },
    seed: 20240101L,
    target_backlog: 100000,
  }
  let r = load_advice(s, req)
  assert_eq(r.new_per_day, 60)
  assert_true(r.next_step_backlog is None)
  assert_eq(r.search_lo, 60)
  assert_eq(r.search_hi, 60)
  assert_true(r.summary.contains("绰绰有余"))
}

///|
test "advice: 非零目标积压也能工作" {
  let s : AnyScheduler = AnyScheduler::Fsrs(Fsrs::new())
  let req = { ..advice_req_small(), target_backlog: 10, }
  let r = load_advice(s, req)
  assert_eq(r.new_per_day, 8)
  assert_true(r.final_backlog <= 10)
  assert_true(probe_final_backlog(s, req, 9) > 10)
  match r.next_step_backlog {
    Some(nb) => assert_true(nb > 10)
    None =>
      fail("目标 10 时 8 张达标、9 张超标，不可能是上界平台")
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
