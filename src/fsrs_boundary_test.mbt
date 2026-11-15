// recall — FSRS 端到端边界（2026-11-15 审计）
//
// 底层恒等式（R(t=S)=0.9、I(S,0.9)=S）已有测试锁定；这里补的是
// **调度器入口**的两条端到端路径：
//
//   1. 恰好在 S 天复习：`Scheduler::retrievability` 在 elapsed=S 时
//      精确 0.9，且 `review` 的新间隔 = round(S')（同一条定义链）。
//   2. 同日重复复习（elapsed < 1）的短期分支：衰减链有 0.1 下限，
//      有限大权重下的增益链在溢出前始终有限（R-6 守卫兜底）。

///|
test "fsrs-edge: 恰在 S 天复习时 R=0.9 且间隔按 round(S') 回写" {
  // 自备权重把 S₀(Good) 顶成整数 10 天，让「S 天」能用整数秒精确表达
  let w = fsrs_default_w()
  w[2] = 10.0
  let s = Fsrs::with_params(w)
  let st0 = Scheduler::init(s, "c", 0L)
  let st1 = Scheduler::review(s, st0, Good, 0L)
  inspect(st1.stability, content="10")
  inspect(st1.interval_days, content="10")
  // 恰在 S 天（= due 时刻）：可提取性精确 0.9 —— S 的定义
  let r = Scheduler::retrievability(s, st1, st1.due)
  let dr = r - 0.9
  inspect(dr.abs() < 0.000000000001, content="true")
  // 恰在 S 天复习：R 取旧 S=10 → 精确 0.9 进成功路径；新稳定性与
  // 直接调公式逐位一致（ds=0），新间隔 = round(S')。
  // 注意「链条继续在 st2 的 S' 天复习同样 R=0.9」**不可**用秒级时间戳
  // 断言：S' 一般非整数，`st2.due` 只能落在 round(S') 上，elapsed 与
  // S' 的取整差会让 R 偏离 0.9 —— 这是时间戳粒度的必然，不是缺陷。
  let expected_s = stability_after_success(w, st1.difficulty, 10.0, 0.9, 3)
  let st2 = Scheduler::review(s, st1, Good, st1.due)
  let ds = st2.stability - expected_s
  inspect(ds.abs() < 0.000000000001, content="true")
  inspect(st2.interval_days, content=@math.round(expected_s).to_string())
  // st2 的 due 恰好推进 round(S') 天（间隔与 due 一致）
  inspect(
    st2.due,
    content=(st1.due + @math.round(expected_s).to_int64() * 86400L).to_string(),
  )
}

///|
test "fsrs-edge: 同日连续 Again 的短期衰减链落到 0.1 下限并停住" {
  let s = Fsrs::new()
  let mut st = Scheduler::init(s, "c", 0L)
  // 首次 Again：走初始公式 S₀(Again)=0.40255（不是短期分支）
  st = Scheduler::review(s, st, Again, 0L)
  inspect(st.stability, content="0.40255")
  // 同日（elapsed=0 < 1）连续 Again：每次 ×exp(w17·(1-3+w18)) ≈ ×0.5011
  // 0.40255 → 0.2017 → 0.1011 → 0.0507（守卫落 0.1）→ 恒 0.1
  let mut saw_below_floor = false
  for i in 0..<12 {
    st = Scheduler::review(s, st, Again, 0L)
    if st.stability < 0.1 {
      saw_below_floor = true
    }
    inspect(st.stability.is_nan(), content="false")
  }
  inspect(saw_below_floor, content="false")
  inspect(st.stability, content="0.1")
  // 稳定性塌到下限时间隔取最小 1 天：卡片每天到期（不会消失）
  inspect(st.interval_days, content="1")
}

///|
test "fsrs-edge: 有限大 w17/w18 的同日 Easy 增益链始终有限" {
  // w17=10、w18=1 都在 validate_fsrs_weights 的合法范围 [0,10]/[0,1] 内，
  // 但同日增益 exp(w17·(g-3+w18)) = exp(20) ≈ 4.85e8 倍/次。
  // R-6 守卫承诺：溢出那一次落 0.1 下限，任何一步都不产出 NaN/±Inf。
  let w = fsrs_default_w()
  w[17] = 10.0
  w[18] = 1.0
  let s = Fsrs::with_params(w)
  let mut st = Scheduler::init(s, "c", 0L)
  st = Scheduler::review(s, st, Good, 0L) // S = S₀(Good) = 3.173
  let mut overflowed = false
  for i in 0..<60 {
    st = Scheduler::review(s, st, Easy, 0L)
    if st.stability.is_nan() || st.stability == 1.0 / 0.0 {
      inspect("step \{i} produced non-finite stability", content="finite")
    }
    if st.stability == 0.1 {
      overflowed = true
    }
    // 间隔恒在 [1, 36500]：due 不回绕，调度器仍可用
    inspect(
      st.interval_days >= 1.0 && st.interval_days <= 36500.0,
      content="true",
    )
  }
  // 60 次 ×exp(20) 必然越过 Double 上限：守卫必须在某一步接住
  inspect(overflowed, content="true")
}
