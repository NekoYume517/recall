///|
/// 审计回归（第十二轮，P2）：`advice` 的探测必须与 `simulate` 的**运行时
/// 工作预算**同源。
///
/// ## 缺陷形态（修复前实测，native release）
///
/// `f3f274c` 给 `simulate` 加了第四道守卫（累计到期条数 > 6e7 即中止），但它
/// 只挂在 `cmd_simulate` 的调用点上。`advice` 的每一次探测**就是**一次
/// `simulate`（`src/advice.mbt` 的 `probe_backlog`），却一次也没走那道预算：
///
///     simulate --days 22361 --new-per-day 1 --review-limit 1  → exit 2，16.38 s
///     advice   --days 22361              --review-limit 1  → exit 0，89.34 s
///     advice   --days 28000              --review-limit 1  → exit 0，174.48 s
///
/// 同一份「要排序/处理的队列长度」在两个入口拿到相反的准入判定，而且
/// `advice` 侧比被拒的那一档**做得更多**（一次探测就 2.5e8 条，是预算的 4.2 倍）。
///
/// ## 判据（不另写计数器）
///
/// `probe_outcome` 直接复用 `simulate_with_budget`，所以两边对同一配置永远
/// 同结论。中止时 `AdviceAbort` 报出「是哪一次探测（`new_per_day`）」+ 那一天的
/// 运行时状态；CLI 转成 exit 2 并给两条可执行建议。
///
/// 注：本文件只测库函数与文案（纯函数、毫秒级）。CLI 端到端
/// （`advice --days 28000 --review-limit 1` 从 174.48 s exit 0 变成 ~16 s exit 2）
/// 的实测记录在 `audit/2026-11-17/recall/REPORT.md` 与 `evidence/` 里。
/// 不把大配置搬进测试套件：那会让每次 `moon test` 多花几十秒（纪律 §6）。

///|
/// 测试用的建议请求。`policy_factory` 每次调用新建随机流，避免探测之间
/// 共用被推进过的 LCG（`API.md` §5.1 的 `policy_factory` 注释）。
fn ab_req(days : Int32, review_limit : Int32) -> @lib.AdviceRequest {
  {
    days,
    review_limit,
    desired_retention: 0.9,
    policy_factory: fn() { @lib.grade_policy_with_seed("realistic", 20240101L) },
    seed: 20240101L,
    target_backlog: 0,
  }
}

///|
test "advice budget: simulate 判死的探测，advice 也必须中止而不是跑完" {
  let s = @lib.AnyScheduler::by_name("fsrs")
  // 200 天 / 复习上限 1：积压随天数线性堆积，累计到期条数很快越过预算。
  let req = ab_req(200, 1)
  let limit : Int64 = 2000L
  // 前提必须在本次运行里成立：同一个配置（n = hi = 1）被 simulate 的预算判死。
  let probe = @lib.simulate_with_budget(s, req.to_config(1), limit)
  let probe_aborted = match probe {
    @lib.Aborted(_) => true
    @lib.Completed(_) => false
  }
  assert_true(probe_aborted)
  // 修复前这里拿到 AdviceCompleted（＝跑完了 simulate 会拒绝的那份模拟）。
  match @lib.load_advice_with_budget(s, req, limit) {
    @lib.AdviceAborted(a) => {
      assert_true(a.sim.limit == limit)
      assert_true(a.sim.work > limit)
      // 中止信息必须能定位到「哪一次探测」：n 是搜索量，不是用户传的参数。
      assert_true(a.new_per_day >= 0 && a.new_per_day <= req.review_limit)
      assert_true(a.sim.day >= 0)
    }
    @lib.AdviceCompleted(_) =>
      fail("advice 跑完了 simulate 会拒绝的探测")
  }
}

///|
test "advice budget: 中止点可复现（两次同一天、同一累计量）" {
  let s = @lib.AnyScheduler::by_name("fsrs")
  let limit : Int64 = 2000L
  let first = match @lib.load_advice_with_budget(s, ab_req(200, 1), limit) {
    @lib.AdviceAborted(a) => a
    @lib.AdviceCompleted(_) => fail("第一次探测没有中止")
  }
  let second = match @lib.load_advice_with_budget(s, ab_req(200, 1), limit) {
    @lib.AdviceAborted(a) => a
    @lib.AdviceCompleted(_) => fail("第二次探测没有中止")
  }
  inspect(first.new_per_day == second.new_per_day, content="true")
  inspect(first.sim.day == second.sim.day, content="true")
  inspect(first.sim.work == second.sim.work, content="true")
  inspect(first.sim.backlog == second.sim.backlog, content="true")
  inspect(first.sim.due_cards == second.sim.due_cards, content="true")
}

///|
test "advice budget: 预算足够时与 load_advice 逐字段相同（同一个搜索）" {
  let s = @lib.AnyScheduler::by_name("fsrs")
  // 小配置：15 天 / 上限 8。搜索次数与单次成本都在毫秒级。
  let limited = match @lib.load_advice_with_budget(s, ab_req(15, 8), 1000000L) {
    @lib.AdviceCompleted(r) => r
    @lib.AdviceAborted(_) => fail("小配置不该撞预算")
  }
  let plain = @lib.load_advice(s, ab_req(15, 8))
  inspect(limited.new_per_day == plain.new_per_day, content="true")
  inspect(limited.final_backlog == plain.final_backlog, content="true")
  inspect(limited.search_lo == plain.search_lo, content="true")
  inspect(limited.search_hi == plain.search_hi, content="true")
  inspect(limited.summary == plain.summary, content="true")
  inspect(
    limited.simulation.total_reviews == plain.simulation.total_reviews,
    content="true",
  )
  inspect(
    limited.simulation.days.length() == plain.simulation.days.length(),
    content="true",
  )
  inspect(
    limited.simulation.max_backlog == plain.simulation.max_backlog,
    content="true",
  )
}

///|
test "advice budget: 预算足够时 --review-limit 0（不限）也照常完成" {
  let s = @lib.AnyScheduler::by_name("fsrs")
  let req = ab_req(10, 0)
  match @lib.load_advice_with_budget(s, req, 1000000L) {
    @lib.AdviceCompleted(r) => inspect(r.search_hi, content="500")
    @lib.AdviceAborted(_) =>
      fail("--review-limit 0 的小配置不该撞预算")
  }
}

///|
test "advice budget: 中止文案报出探测速率、累计量、预算与两条可执行建议" {
  let abort : @lib.AdviceAbort = {
    new_per_day: 7,
    sim: {
      day: 10958,
      backlog: 10956,
      due_cards: 10957,
      work: 60008566L,
      limit: 60000000L,
    },
  }
  let msg = advice_budget_error(abort, 28000, 1)
  assert_true(msg.contains("--new-per-day 7"))
  assert_true(msg.contains("28000"))
  assert_true(msg.contains("60000000"))
  assert_true(msg.contains("60008566"))
  assert_true(msg.contains("第 10959 天"))
  // 建议必须可执行：把 --days 降到中止那天之前。
  assert_true(msg.contains("把 --days 降到 10958 以内"))
  // 逃生口。
  assert_true(msg.contains("--review-limit 0"))
}

///|
test "advice budget: 第 0 天就中止时不给「降到 0 天」这种不可执行建议" {
  let abort : @lib.AdviceAbort = {
    new_per_day: 3,
    sim: { day: 0, backlog: 3, due_cards: 3, work: 4L, limit: 3L, },
  }
  let msg = advice_budget_error(abort, 5, 3)
  assert_false(msg.contains("把 --days 降到 0"))
  assert_true(msg.contains("第 1 天就超预算"))
}
