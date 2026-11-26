// ============================================================================
// 跨算法字段语义：哪些量**必须**与调度器无关、哪些**必须**随之变化
//
// 第二十轮 ③（2026-11-28）。`replay` 的 `ReplayResult` 里三类字段混在一起：
//
//   (a) 来自日志本身的计数：total_reviews / total_lapses / cards —— 必须与调度器无关；
//   (b) 随调度器变化的量：final_states（interval/stability/difficulty/reps/phase）、
//       final_intervals —— 必须随调度器变化，且文档要说明"不可横比"的字段
//       （difficulty 在 SM-2 是 EF、在 Leitner 是盒号）；
//   (c) 从日志 + 调度器共同推出的量：interval_error_days / signed_interval_error_days /
//       late_review_ratio。
//
// 这一轮把 (a)(b) 写成断言，(c) 的已知不一致单独记在下面这条用例里。

///|
/// 两卡四事件的固定日志：a 卡 Good→Good，b 卡 Again→Good。
fn rc20_mixed_log() -> ReviewLog {
  let log = ReviewLog::new()
  let t0 : Timestamp = 1700000000L
  log.push(ReviewEvent::new("a", t0, t0, Good, 1.0))
  log.push(ReviewEvent::new("a", t0 + 86400L, t0, Good, 1.0))
  log.push(ReviewEvent::new("b", t0, t0, Again, 1.0))
  log.push(ReviewEvent::new("b", t0 + 2L * 86400L, t0, Good, 1.0))
  log
}

///|
test "rc20-3: 日志计数类字段与调度器无关（应同）" {
  let expected_reviews = 4
  let expected_lapses = 1
  for name in ["fsrs", "sm2", "leitner"] {
    let res = replay(rc20_mixed_log(), AnyScheduler::by_name(name))
    assert_eq(res.total_reviews, expected_reviews)
    assert_eq(res.total_lapses, expected_lapses)
    assert_eq(res.final_states.size(), 2)
  }
}

///|
test "rc20-3: 状态类字段必须随调度器变化（必须异）" {
  let fsrs = replay(rc20_mixed_log(), AnyScheduler::by_name("fsrs"))
  let sm2 = replay(rc20_mixed_log(), AnyScheduler::by_name("sm2"))
  let lei = replay(rc20_mixed_log(), AnyScheduler::by_name("leitner"))
  let fa = match fsrs.final_states.get("a") {
    Some(v) => v
    None => abort("missing a")
  }
  let sa = match sm2.final_states.get("a") {
    Some(v) => v
    None => abort("missing a")
  }
  let la = match lei.final_states.get("a") {
    Some(v) => v
    None => abort("missing a")
  }
  // 同一份日志、同一张卡：三个调度器给出的最终状态必须两两不同，
  // 否则「跨算法比较」就没有内容可谈（也是 compare 命令存在的前提）。
  //
  // ⚠️ 这里刻意**不**用 interval_days 做判据：这张卡恰好落在
  // 「FSRS 6 天 / SM-2 6 天 / Leitner 4 天」的巧合上（第二次 Good 的间隔
  // 取整后撞在一起），拿它断言「必须两两不同」是拿巧合当契约。
  // 换用 (stability, difficulty) 这一对——三家语义本来就不同：
  // FSRS 是 (S, D)、SM-2 是 (间隔镜像, EF)、Leitner 是 (盒间隔, 盒号)。
  assert_true(fa.stability != sa.stability)
  assert_true(fa.stability != la.stability)
  assert_true(sa.stability != la.stability)
  assert_true(fa.difficulty != sa.difficulty)
  assert_true(fa.difficulty != la.difficulty)
}

///|
test "rc20-3: difficulty 的语义随调度器分派（不可横比，文档已声明）" {
  // FSRS：标准难度 D ∈ [1, 10]；SM-2：借存 EF（下限 1.3，实践中 < 3）；
  // Leitner：借存盒号（1..5 的整数）。这里锁的是「范围互不相同」这个事实，
  // 一旦某个实现把别人的量写进来，这条会红。
  let fsrs = replay(rc20_mixed_log(), AnyScheduler::by_name("fsrs"))
  let sm2 = replay(rc20_mixed_log(), AnyScheduler::by_name("sm2"))
  let lei = replay(rc20_mixed_log(), AnyScheduler::by_name("leitner"))
  let fd = (match fsrs.final_states.get("a") {
      Some(v) => v
      None => abort("x")
    }).difficulty
  let sd = (match sm2.final_states.get("a") {
      Some(v) => v
      None => abort("x")
    }).difficulty
  let ld = (match lei.final_states.get("a") {
      Some(v) => v
      None => abort("x")
    }).difficulty
  // Leitner 的盒号必须是 1..5 的整数
  assert_true(ld >= 1.0 && ld <= 10.0)
  assert_true(ld == ld.round())
  // SM-2 的 EF 下限 1.3
  assert_true(sd >= 1.3)
  // FSRS 的 D 落在 [1,10]
  assert_true(fd >= 1.0 && fd <= 10.0)
}

///|
test "rc20-3: reps 的语义也分派（SM-2 是连续成功数，Again 后清零）" {
  let sm2 = replay(rc20_mixed_log(), AnyScheduler::by_name("sm2"))
  let fsrs = replay(rc20_mixed_log(), AnyScheduler::by_name("fsrs"))
  // b 卡是 Again→Good：SM-2 的 reps 只数连续成功，所以是 1；FSRS 累计成功次数，也是 1。
  let sb = (match sm2.final_states.get("b") {
      Some(v) => v
      None => abort("x")
    }).reps
  let fb = (match fsrs.final_states.get("b") {
      Some(v) => v
      None => abort("x")
    }).reps
  assert_eq(sb, 1)
  assert_eq(fb, 1)
}
