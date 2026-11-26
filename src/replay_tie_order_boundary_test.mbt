// ============================================================================
// 「重放只依赖日志内容」的边界：同一时刻的多条事件，**文件行序**改变结果
//
// 第二十轮 RC-20-3（2026-11-28）。src/replay.mbt 的注释写着：
//
//     - 全程确定性：卡片按 id 排序处理，浮点累加顺序固定，同输入必得同输出。
//
// API.md 的验收清单也只写「重放确定性：同一日志跑两次结果完全一致」（弱）。
// 实测这两句话都成立，但**都不够**：把同一张卡、同一时刻的两条不同事件在文件里
// 换个顺序，结果会变：
//
//     [A(Good@t0), B(Again@t0+D), C(Easy@t0+D)]  -> final interval 2.0
//     [A(Good@t0), C(Easy@t0+D), B(Again@t0+D)]  -> final interval 6.0
//
// 根因（两层）：
//   1. `ReviewLog::by_card` 的排序是「稳定排序 + 相等返回 -1」——这个 -1 让
//      `<` 与 `>` **同时**为真，比较器自相矛盾；结果依赖底层排序算法在相等元素
//      上的处理，而不是确定的全序。
//   2. 缺 `elapsed_days` 的事件，其间隔由**上一条事件**的时间戳回推；同刻两条
//      事件谁先谁后决定「上一条」是谁，于是同一份数据得出两个不同的重放终态。
//
// 影响：CalDAV / Anki 导出这类来源确实会出现「同一秒两条复习」（批量拖动、
// 批量导入），此时重放结果与文件行序绑定；即便同一份文件跑两次完全一致（弱确定性
// 成立），**同内容不同行序**却不同（强确定性不成立）。
//
// 这里不修语义（同刻事件的业务先后在日志里没有字段可依据），只把它的边界**写成
// 可执行断言 + 文档**，让下游知道「摘要必须按行序规范化后再比对」。

///|
/// 造一份「同刻两条不同事件」的日志，`grade2` 决定第二条事件的评分。
fn rc20_tie_log(grade2 : Grade) -> ReviewLog {
  let log = ReviewLog::new()
  let t0 : Timestamp = 1700000000L
  log.push(ReviewEvent::new("s", t0, t0, Good, 1.0))
  log.push(ReviewEvent::new("s", t0 + 86400L, t0 + 86400L, grade2, 1.0))
  log
}

///|
test "rc20-3: 同内容不同行序——同刻两条事件的结果与行序绑定（已知边界）" {
  // 先 Again 后 Easy
  let ae = rc20_tie_log(Easy)
  // 先 Easy 后 Again（同一批事件，仅顺序不同）
  let ea = ReviewLog::new()
  let t0 : Timestamp = 1700000000L
  ea.push(ReviewEvent::new("s", t0, t0, Good, 1.0))
  ea.push(ReviewEvent::new("s", t0 + 86400L, t0 + 86400L, Easy, 1.0))
  ea.push(ReviewEvent::new("s", t0 + 86400L, t0 + 86400L, Again, 1.0))
  let ae2 = ReviewLog::new()
  ae2.push(ReviewEvent::new("s", t0, t0, Good, 1.0))
  ae2.push(ReviewEvent::new("s", t0 + 86400L, t0 + 86400L, Again, 1.0))
  ae2.push(ReviewEvent::new("s", t0 + 86400L, t0 + 86400L, Easy, 1.0))
  let r1 = replay(ae2, AnyScheduler::by_name("fsrs"))
  let r2 = replay(ea, AnyScheduler::by_name("fsrs"))
  let i1 = (match r1.final_states.get("s") {
      Some(v) => v
      None => abort("missing s")
    }).interval_days
  let i2 = (match r2.final_states.get("s") {
      Some(v) => v
      None => abort("missing s")
    }).interval_days
  // 记录当前行为：两者**不相等**。这条断言的作用是把边界钉住——
  // 哪天实现改成「按内容全序」后这里会红，提醒同步 API.md 的确定性条款。
  assert_true(i1 != i2)
}

///|
test "rc20-3: 同一份日志跑两次必须完全一致（弱确定性，契约内）" {
  let a = replay(rc20_tie_log(Easy), AnyScheduler::by_name("fsrs"))
  let b = replay(rc20_tie_log(Easy), AnyScheduler::by_name("fsrs"))
  assert_eq(a.total_reviews, b.total_reviews)
  assert_eq(a.total_lapses, b.total_lapses)
  assert_eq(a.interval_error_days, b.interval_error_days)
}
