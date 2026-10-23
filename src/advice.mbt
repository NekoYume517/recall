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
// 搜索策略：**从搜索上界向下线性扫描**，返回第一个达标的 n。
//
// 为什么不是二分：积压对 new_per_day **不是单调的**。旧注释曾断言
// 「new_per_day 与最终积压单调相关（这是构造保证）」，该前提已被实测证伪：
// 评分策略按真实 elapsed 抽样，种子固定但随机流被 n 改变的路径是非线性的，
// 于是曲线出现回落。实测反例（90 天 / 上限 150 / optimistic）：
//   f(43)=422, f(44)=526, f(45)=465, f(46)=522
// 二分在 44 就被挡住，返回 43 并声称「第 44 张会升到 526 超出目标」，
// 而 45 其实达标。另一处回落：f(55)=480 → f(56)=424（上限 200）。
//
// 因此搜索必须逐个检查：从上界往下，第一个 f(n) <= target 的 n 就是真实
// 最大值（所有更大的 n 都已验证超标）。成本最坏 O(hi) 次模拟，命中即停。
// 可复现性不受影响：每次 probe 都是同一配置的确定性模拟。

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
// 线性扫描
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
/// 搜索方式：**从 hi 向下逐张扫描**，返回第一个达标的 n。积压对
/// new_per_day 非单调（见文件顶部反例），所以不能二分，也不能跳步：
/// 跳过任何一个 n 都可能漏掉上方那个真实最大值。
///
/// 复杂度：最坏 O(hi) 次模拟，每次模拟 O(days × cards)；命中即停，
/// 上界附近就有解时只需几次。90 天 / 上限 150 / 目标 500 时实测
/// 共 107 次模拟（1 次 f(0) + 1 次 f(hi) + 105 次扫描）。
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
  // 线性扫描：hi 已确认超标，从 hi-1 往下找第一个达标点。
  // `next_backlog` 始终保存「上一个（更大的）n」的积压，即 f(candidate+1)。
  let mut candidate = hi - 1
  let mut next_backlog = hi_backlog
  while candidate > 0 {
    let backlog = probe_backlog(s, req, candidate)
    if backlog <= req.target_backlog {
      // 更大的 n 全部已实测超标，所以这就是真实最大值
      let sim = simulate(s, req.to_config(candidate))
      return {
        new_per_day: candidate,
        simulation: sim,
        final_backlog: backlog,
        next_step_backlog: Some(next_backlog),
        search_lo: 0,
        search_hi: hi,
        summary: "每天 \{candidate} 张新卡可在 \{req.days} 天内把积压控制在 \{backlog}（目标 \{req.target_backlog}）；第 \{candidate + 1} 张会升到 \{next_backlog}",
      }
    }
    next_backlog = backlog
    candidate = candidate - 1
  }
  // 走到这里：f(0) 达标（入口已验证），f(1)（= next_backlog）超标
  let sim = simulate(s, req.to_config(0))
  {
    new_per_day: 0,
    simulation: sim,
    final_backlog: lo_backlog,
    next_step_backlog: Some(next_backlog),
    search_lo: 0,
    search_hi: hi,
    summary: "每天最多 0 张新卡：多学 1 张就会让积压（\{next_backlog}）超过目标 \{req.target_backlog}",
  }
}
