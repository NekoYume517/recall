// recall — 负载优化建议器
//
// 合同：PLAN.md 后续路线第 2 项。
//
// 回答的问题：「我想在 D 天内把积压控制住 / 清零，每天最多能学几张新卡？」
//
// 方法：**模拟搜索**，不是解析解。原因：积压动力学是非线性的
// （Again → 间隔回退 → 更多到期 → 更多积压 → 评分策略感知逾期更悲观），
// 解析近似会漏掉「积压自我强化」这个最重要的现象。模拟器的确定性
// （固定种子、逐字节可复现）让搜索结果本身也可复现——同样的配置
// 每次给出同一个建议，这是"建议"区别于"猜测"的底线。
//
// 搜索策略：**二分**。new_per_day 与最终积压单调相关（每天多学一张卡
// 不会让最终积压更少——这是构造保证：多学的卡只会增加到期量，不会
// 减少已有卡的复习量），所以可以二分。单调性由 `advice_monotonic`
// 测试在多个配置下验证。

// ---------------------------------------------------------------------------
// 建议请求与结果
// ---------------------------------------------------------------------------

///|
/// 建议请求。
pub(all) struct AdviceRequest {
  /// 模拟天数（建议窗口）
  days : Int32
  /// 每天最多复习数，0 = 无限
  review_limit : Int32
  /// 目标保持率
  desired_retention : Double
  /// 评分策略工厂：每次模拟调用一次，新建带独立随机流的策略实例。
  /// 不能直接放闭包实例——LCG 有状态，多次 probe 会互相污染随机流。
  policy_factory : () -> (CardState) -> Grade
  /// 随机种子（必须显式给出：建议要可复现，种子是配置的一部分）
  seed : Int64
  /// 积压目标：窗口结束时允许的最大积压。
  /// 0 = 完全清零（最严格）
  target_backlog : Int32
} derive(Debug)

///|
/// 建议结果。
pub(all) struct AdviceResult {
  /// 推荐的每日新卡数
  new_per_day : Int32
  /// 该速率下的模拟结果（供展示"为什么"）
  simulation : SimResult
  /// 该速率下的最终积压
  final_backlog : Int32
  /// 比推荐值多 1 张时的最终积压（展示"为什么不能更多"）；
  /// 推荐值已是上限（0 或 max）时为 None
  next_step_backlog : Int32?
  /// 搜索范围下界（结果可信度参考：0 表示"连完全不学新卡都清不了积压"）
  search_lo : Int32
  /// 搜索范围上界
  search_hi : Int32
  /// 人类可读的一句话结论
  summary : String
} derive(Debug)

///|
/// 建议请求默认值：90 天窗口、复习上限 200、90% 保持率、
/// realistic 策略（固定默认种子）、积压清零。
pub fn AdviceRequest::default() -> AdviceRequest {
  {
    days: 90,
    review_limit: 200,
    desired_retention: 0.9,
    policy_factory: fn() { grade_policy_with_seed("realistic", 20240101L) },
    seed: 20240101L,
    target_backlog: 0,
  }
}

// ---------------------------------------------------------------------------
// 核心：单点评估
// ---------------------------------------------------------------------------

///|
/// 给定每日新卡数，跑一次模拟并返回最终积压。
fn probe_backlog(
  s : AnyScheduler,
  req : AdviceRequest,
  new_per_day : Int32,
) -> Int32 {
  simulate(s, req.to_config(new_per_day)).final_backlog
}

///|
/// 从建议请求生成对应速率的模拟配置（内部辅助，公开为纯函数便于测试）。
pub fn AdviceRequest::to_config(
  self : AdviceRequest,
  new_per_day : Int32,
) -> SimConfig {
  {
    days: self.days,
    new_per_day,
    review_limit: self.review_limit,
    desired_retention: self.desired_retention,
    grade_fn: (self.policy_factory)(),
    seed: self.seed,
  }
}

///|
/// 单点评估的公开入口：「如果每天学 N 张新卡，窗口结束时积压多少？」
///
/// `load_advice` 的构件；单独暴露是因为用户经常只想问一个点，
/// 不需要搜索整个区间。
pub fn probe_final_backlog(
  s : AnyScheduler,
  req : AdviceRequest,
  new_per_day : Int32,
) -> Int32 {
  probe_backlog(s, req, new_per_day)
}

// ---------------------------------------------------------------------------
// 二分搜索
// ---------------------------------------------------------------------------

///|
/// 负载建议：搜索「窗口结束时积压 ≤ target 的最大每日新卡数」。
///
/// 搜索范围 [0, hi]：
///   - 下界 0：完全不学新卡。若连这样都清不了积压（存量太大），
///     结果是 0 并在 summary 里明说——**不猜、不编一个好看的数**。
///   - 上界 hi = review_limit（0 = 无限时取 500）：新卡占用复习配额，
///     学新卡的速度不可能超过复习能力，超过的部分没有意义。
///
/// 复杂度：O(log hi) 次模拟。每次模拟 O(days × cards)。
/// 90 天 / 上限 500 时约 9 次模拟，秒级完成。
///
/// **可复现承诺**：同样输入（含种子）永远给同样输出——模拟器确定性
/// 传递到这一层。测试 `advice_deterministic` 锁定。
pub fn load_advice(s : AnyScheduler, req : AdviceRequest) -> AdviceResult {
  let hi = if req.review_limit > 0 { req.review_limit } else { 500 }
  // 边界检查：0 张新卡能否达标
  let lo_backlog = probe_backlog(s, req, 0)
  if lo_backlog > req.target_backlog {
    // 存量积压连"停学新卡"都消化不了——如实说，建议为 0
    let sim = simulate(s, req.to_config(0))
    return {
      new_per_day: 0,
      simulation: sim,
      final_backlog: lo_backlog,
      next_step_backlog: None,
      search_lo: 0,
      search_hi: hi,
      summary: "即使每天 0 张新卡，\{req.days} 天后仍有 \{lo_backlog} 张积压（目标 \{req.target_backlog}）——存量太大，先提高复习上限或延长窗口",
    }
  }
  // 二分：找最大的 new_per_day 使 final_backlog <= target
  // 不变量：f(0) 达标（刚验证过），f(hi+1) 不达标或 hi 是上界
  let mut lo = 0
  let mut cur = hi
  // 先看上界本身是否达标：达标则直接返回上界（不用搜）
  let hi_backlog = probe_backlog(s, req, hi)
  if hi_backlog <= req.target_backlog {
    let sim = simulate(s, req.to_config(hi))
    return {
      new_per_day: hi,
      simulation: sim,
      final_backlog: hi_backlog,
      next_step_backlog: None,
      search_lo: hi,
      search_hi: hi,
      summary: "\{req.days} 天窗口内即使每天 \{hi} 张新卡（复习上限），积压也只有 \{hi_backlog}（目标 \{req.target_backlog}）——容量绰绰有余，可以调大 review_limit 或缩短窗口",
    }
  }
  // 标准二分：保持 f(lo) 达标、f(cur) 不达标，收敛到 lo = cur - 1
  while cur - lo > 1 {
    let mid = (lo + cur) / 2
    if probe_backlog(s, req, mid) <= req.target_backlog {
      lo = mid
    } else {
      cur = mid
    }
  }
  // lo 达标、lo+1 不达标
  let final_backlog = probe_backlog(s, req, lo)
  let next_backlog = probe_backlog(s, req, lo + 1)
  let sim = simulate(s, req.to_config(lo))
  let summary = if lo == 0 {
    "每天最多 0 张新卡：多学 1 张就会让积压（\{next_backlog}）超过目标 \{req.target_backlog}"
  } else {
    "每天 \{lo} 张新卡可在 \{req.days} 天内把积压控制在 \{final_backlog}（目标 \{req.target_backlog}）；第 \{lo + 1} 张会升到 \{next_backlog}"
  }
  {
    new_per_day: lo,
    simulation: sim,
    final_backlog,
    next_step_backlog: Some(next_backlog),
    search_lo: 0,
    search_hi: hi,
    summary,
  }
}
