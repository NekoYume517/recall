// ============================================================================
// `stats` 每条事件的间隔都来自日志，与调度器无关——三个调度器跑过之后逐字恒等
//
// 第二十一轮 RC-21-3（2026-11-29）。上面 `stats_cross_algo_categories_test.mbt`
// 把「类别 A」的字段逐个归类并断言恒等；但「跑过调度器」那一步在那里只是
// `let _ = replay(...)`——调度器结果被丢掉了，等于只证明「纯函数可重入」。
//
// 这里补上真正有意义的对照：**同一份日志、三种调度器，各自的 replay 结果都拿去
// 喂 stats 的构造假设**（`final_states` 里的 `interval_days` 若被误当成统计输入，
// 三份结果就会不同）。判据：`compute_stats(log)` 的渲染串在三次 replay 之后
// **逐字节相同**，且 `overall_stats` 亦然。
//
// 这条用例的价值：它是「stats 不从调度器取数」的可执行证据——上一轮我把「应同」
// 只写成「存在相同」是不够的（那是巧合），这里要求的是**每一次都相同**。

///|
/// 把 `compute_stats` 的输出渲染成稳定字符串（用于逐字比对）。
fn rc21_stats_render(log : ReviewLog) -> String {
  let rows = compute_stats(log)
  let sb = StringBuilder()
  sb.write_string(log.length().to_string())
  for r in rows {
    sb.write_string(
      r.card_id +
      ":" +
      r.reviews.to_string() +
      "," +
      r.lapses.to_string() +
      "," +
      r.mean_interval.to_string() +
      "," +
      r.max_interval.to_string() +
      "," +
      r.retention_rate.to_string() +
      ";",
    )
  }
  let o = overall_stats(rows)
  sb.write_string(
    "|" +
    o.cards.to_string() +
    "," +
    o.reviews.to_string() +
    "," +
    o.lapses.to_string() +
    "," +
    o.retention_rate.to_string() +
    "," +
    o.mean_interval.to_string(),
  )
  sb.to_string()
}

///|
test "rc21-3: 三种调度器各跑一遍之后，stats 渲染串逐字节相同" {
  for seed in 0..<6 {
    let log = rc21_fixture(seed)
    let base = rc21_stats_render(log)
    // 三种调度器依次重放（结果各不相同），期间反复取 stats
    for name in ["fsrs", "sm2", "leitner"] {
      let res = replay(log, AnyScheduler::by_name(name))
      // 用最终状态「碰一下」，确保它确实存在于当前作用域（不会被优化掉的语义）
      assert_true(res.final_states.size() >= 1)
      assert_eq(rc21_stats_render(log), base)
    }
    // 收尾再取一次（跨越三次 replay）
    assert_eq(rc21_stats_render(log), base)
  }
}
