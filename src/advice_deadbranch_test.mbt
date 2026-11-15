// recall — advice「存量太大」分支的可达性佐证（2026-11-15 审计）
//
// `load_advice` 的「即使每天 0 张新卡也清不了存量」分支要求
// `probe_backlog(s, req, 0) > req.target_backlog`。但模拟器从**空状态**
// 起步：new_per_day=0 时没有任何卡进入模拟，最终积压恒为 0；而
// target_backlog < 0 已在入口被 RJ-A5 分支拦下。因此
// `0 > target ≥ 0` 恒假 —— 该分支当前不可达，只是防御性代码。
// API.md §5.1 的「三个诚实分支」第一条据此修正口径（docs 同轮提交）。
// 若将来 simulate 支持「预置存量」输入，这条测试和该分支都会重新
// 有意义。

///|
test "advice: new_per_day=0 时最终积压恒为 0（从空状态起步）" {
  let s : AnyScheduler = AnyScheduler::Fsrs(Fsrs::new())
  // 用最悲观的策略与各种窗口/上限组合：没有卡，就没有积压
  for days in [1, 10, 30] {
    for rl in [0, 5, 200] {
      let req : AdviceRequest = {
        days,
        review_limit: rl,
        desired_retention: 0.9,
        policy_factory: fn() { grade_policy_with_seed("pessimistic", 42L) },
        seed: 42L,
        target_backlog: 0,
      }
      inspect(probe_final_backlog(s, req, 0), content="0")
    }
  }
}
