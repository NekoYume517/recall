// ============================================================================
// advice 在「复习不限」时的结论文案（2026-11-12 审计 R-7）
//
// ## 现象
//
//   $ moon run cmd/recall -- advice --scheduler fsrs --days 15 \
//       --review-limit 0 --target-backlog 0
//   参数: 15 天窗口, 复习上限 不限, 积压目标 0 张, ...
//   → 推荐每天新卡: 500 张
//   15 天窗口内即使每天 500 张新卡（复习上限），积压也只有 0（目标 0）
//   ——容量绰绰有余，可以调大 review_limit 或缩短窗口
//
// 紧邻的三段自相矛盾：
//   1. 参数行刚说「复习上限 不限」，结论里把 500 称作「（复习上限）」；
//   2. 「可以调大 review_limit」——它已经是 0（不限），没有更大的值；
//   3. 500 其实是 `load_advice` 为「复习不限」配置写死的**搜索上界**
//      （`hi = if review_limit > 0 { review_limit } else { 500 }`），
//      与容量无关，却被当成容量上限来解读。
//
// ## 根因
//
// src/advice.mbt 的「上界达标」分支只有一条文案，把 `hi` 无条件说成
// 「（复习上限）」并建议调大 `review_limit`。`hi` 的两种来源
// （= review_limit / = 500 兜底）在文案里没有区分。
//
// ## 判级
//
// P3：不改任何数值，只误导解读。但它**给出了一个不可能执行的建议**
// （调大一个已经是不限的参数），属于「打印值/结论必须等于生效值」这一族
// ——项目已经为同类问题修过 R1（打印未生效的 retention）与 R-3。
// ============================================================================

///|
/// 15 天窗口、乐观策略（必然达标，走「上界达标」分支）的建议请求。
fn r7_request(review_limit : Int32) -> AdviceRequest {
  {
    days: 15,
    review_limit,
    desired_retention: 0.9,
    policy_factory: fn() { optimistic_policy() },
    seed: 20240101L,
    target_backlog: 0,
  }
}

///|
test "R-7: 复习不限时不把搜索上界说成复习上限、不建议调大 review_limit" {
  let req = r7_request(0)
  let r = load_advice(AnyScheduler::by_name("fsrs"), req)
  println("summary = " + r.summary)
  // 500 是「复习不限」时的固定搜索上界，结论里必须如实说明出处
  assert_true(r.summary.contains("搜索上界"))
  // 「调大 review_limit」在不限配置下是不可能执行的建议
  assert_false(r.summary.contains("调大 review_limit"))
  // 不能再把 hi 称作「（复习上限）」
  assert_false(r.summary.contains("（复习上限）"))
  // 数值行为不变：仍然返回那个搜索上界
  inspect(r.new_per_day, content="500")
  inspect(r.search_hi, content="500")
}

///|
test "R-7: 复习有上限时文案保持原样（新措辞只属于不限配置）" {
  let req = r7_request(5)
  let r = load_advice(AnyScheduler::by_name("fsrs"), req)
  println("summary(limit=5) = " + r.summary)
  // 有限配置下不得出现「不限」相关的免责说明
  assert_false(r.summary.contains("复习不限"))
  assert_false(r.summary.contains("搜索上界"))
}

///|
test "R-7: 不限配置的推荐值与有限配置的推荐值口径一致（都是可达的实测值）" {
  // 两条路径都必须给出「该速率下真的跑过一遍模拟」的积压，而不是估算
  let unlimited = load_advice(AnyScheduler::by_name("fsrs"), r7_request(0))
  assert_eq(
    unlimited.final_backlog,
    probe_final_backlog(
      AnyScheduler::by_name("fsrs"),
      r7_request(0),
      unlimited.new_per_day,
    ),
  )
  let limited = load_advice(AnyScheduler::by_name("fsrs"), r7_request(5))
  assert_eq(
    limited.final_backlog,
    probe_final_backlog(
      AnyScheduler::by_name("fsrs"),
      r7_request(5),
      limited.new_per_day,
    ),
  )
}
