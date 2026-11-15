// recall — 运行时工作预算的恰好边界（2026-11-15 审计）
//
// simulate_with_budget 的判据是 `work > work_limit` 才中止：
// **work 恰好等于预算时必须放行**。这条用例用可控构造把 Σ due_cards
// 精确顶到预算值上，双向锁定 `>` 的边界语义。
//
// 构造：Leitner + 恒 Again + new_per_day=1 + review_limit=0（不限）。
// 每张卡每次 Again 都回盒 1、间隔 1 天，于是第 d 天恰好有 d+1 张卡
// 同时到期（卡 0..d-1 各自到期 + 当天新卡），Σ due_cards(d=0..days-1)
// = days·(days+1)/2 —— 没有任何随机性，逐日可手算。

///|
fn again_cfg(days : Int32) -> SimConfig {
  {
    days,
    new_per_day: 1,
    review_limit: 0,
    desired_retention: 0.9,
    grade_fn: fn(_cs) { Again },
    seed: 20240101L,
  }
}

///|
test "budget-edge: work 恰好等于预算时放行（> 而不是 >=）" {
  let s = AnyScheduler::Leitner(Leitner::new())
  // days=1000 → Σ = 1000·1001/2 = 500500
  let sum : Int64 = 500500L
  match simulate_with_budget(s, again_cfg(1000), sum) {
    Completed(r) => {
      inspect(r.days.length(), content="1000")
      // 逐日 due_cards 手算锚点：第 d 天 = d+1
      inspect(r.days[0].due_cards, content="1")
      inspect(r.days[999].due_cards, content="1000")
      inspect(r.final_backlog, content="0")
    }
    Aborted(x) => inspect("aborted day=\{x.day}", content="completed")
  }
}

///|
test "budget-edge: work 比预算多 1 时中止，且中止点可复现" {
  let s = AnyScheduler::Leitner(Leitner::new())
  // days=1001 → Σ = 1001·1002/2 = 501501 > 500500，超界发生在第 1000 天
  // （0 基）：累计 500500 + 1001 = 501501。
  match simulate_with_budget(s, again_cfg(1001), 500500L) {
    Completed(_) => inspect("completed", content="aborted")
    Aborted(x) => {
      inspect(x.day, content="1000")
      inspect(x.due_cards, content="1001")
      inspect(x.work, content="501501")
      inspect(x.limit, content="500500")
      // rl=0（不限）：当天的 1001 张全部复习完，积压为 0
      inspect(x.backlog, content="0")
      // 同参数重跑：判定点逐字段相同（与墙钟无关）
      match simulate_with_budget(s, again_cfg(1001), 500500L) {
        Completed(_) => inspect("completed", content="aborted")
        Aborted(y) => {
          inspect(y.day, content=x.day.to_string())
          inspect(y.work, content=x.work.to_string())
        }
      }
    }
  }
}

///|
test "budget-edge: 中止那天之前的天数必然放行（建议值可证性）" {
  let s = AnyScheduler::Leitner(Leitner::new())
  // 中止建议「--days 降到 x.day 以内」：覆盖第 0..x.day-1 天的累计量
  // 必然 ≤ 预算（预算是第 x.day 天才超的）。x.day = 1000 → days=1000 放行。
  match simulate_with_budget(s, again_cfg(1000), 500500L) {
    Completed(_) => inspect("ok", content="ok")
    Aborted(x) => inspect("aborted day=\{x.day}", content="ok")
  }
}
