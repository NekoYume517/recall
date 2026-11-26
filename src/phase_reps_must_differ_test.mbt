// ============================================================================
// `CardState.phase` 与 `CardState.reps` 的「必须异」——各一条最小构造
//
// 第二十一轮裁决追加（Lead 2026-11-29）：上一轮的字段归类表把这两个字段归进
// 「必须异」类，但只写了注释、没有断言。本轮补上，**且不贪全**：
//
//   > 只写「三调度器在该字段上至少两两不同」的构造，够证明这一格被覆盖即可。
//   > 不值得为每个调度器逐值写期望值（那是把算法抄进测试，抄错了测试也错）。
//
// 所以下面两条用例的断言形态是「**不是三家全等**」，而不是「FSRS 必须是 Review、
// SM-2 必须是 Learning…」。后者会把三份算法的 stage 机抄进测试文件——一旦算法
// 因故调整，测试跟着错，而且错的方向是「跟着实现改断言」而不是「发现实现变了」。
//
// 构造与实测（native release，`replay --scheduler X --anki` 的 phase 列）：
//
//   **phase**：Good@0、Good@30 天（两次成功复习）
//       FSRS   = Review   （第二次成功 → Review）
//       SM-2   = Learning （SM-2 的 Learning 门槛是「间隔 < 1 天」，这里间隔更长但
//                          reps 只有 2，仍停在 Learning）
//       Leitner= Review   （间隔 ≥ 1 天即视作 Review）
//     → 三家**不全等**（FSRS 与 SM-2 就不同），这一格被覆盖。
//
//   **reps**：Good@0、Good@20、Again@40 天
//       FSRS   = 2（只数成功，Again 不增不减）
//       SM-2   = 0（连续成功数，Again 清零）
//       Leitner= 2（累计成功数，Again 不增不减）
//     → 三家**不全等**（SM-2 与另两家不同）。

///|
/// 造一份「同一张卡、按给定 (天偏移, 评分) 序列复习」的日志。
fn rc21b_seq(seq : Array[(Int64, Int32)]) -> ReviewLog {
  let log = ReviewLog::new()
  let t0 : Timestamp = 1700000000L
  for pair in seq {
    let ts = t0 + 86400L * pair.0
    log.push(ReviewEvent::new("k", ts, ts, Grade::from_int(pair.1), 1.0))
  }
  log
}

///|
/// 取某调度器下 `k` 卡的 (phase, reps)；卡不存在时 abort（fixture 有问题）。
fn rc21b_phase_reps(log : ReviewLog, sched : String) -> (Phase, Int32) {
  let res = replay(log, AnyScheduler::by_name(sched))
  match res.final_states.get("k") {
    Some(v) => (v.phase, v.reps)
    None => abort("fixture card missing")
  }
}

///|
test "rc21b: phase——三调度器在同一份日志上不全等（Good@0 + Good@30）" {
  let log = rc21b_seq([(0L, 3), (30L, 3)])
  let (pf, _) = rc21b_phase_reps(log, "fsrs")
  let (ps, _) = rc21b_phase_reps(log, "sm2")
  let (pl, _) = rc21b_phase_reps(log, "leitner")
  // 只断言「不全等」：不为三家写死各自的期望阶段
  assert_true(!(pf == ps && ps == pl))
  // 实测这一组是 FSRS=Review、SM-2=Learning、Leitner=Review，
  // 所以下面这条也成立（但它是**推论**，不是本用例的判据主体）：
  assert_true(pf != ps)
}

///|
test "rc21b: reps——三调度器在同一份日志上不全等（Good,Good,Again）" {
  let log = rc21b_seq([(0L, 3), (20L, 3), (40L, 0)])
  let (_, rf) = rc21b_phase_reps(log, "fsrs")
  let (_, rs) = rc21b_phase_reps(log, "sm2")
  let (_, rl) = rc21b_phase_reps(log, "leitner")
  assert_true(!(rf == rs && rs == rl))
  // 实测：FSRS=2（只数成功）、SM-2=0（连续成功被 Again 清零）、Leitner=2
  assert_true(rs == 0)
  assert_true(rf == rl)
}
