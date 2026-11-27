// ============================================================================
// 零间隔样本独占一桶（第二十二轮 RC-22-1，2026-11-30）
//
// 现象：同卡多事件时，一条 `elapsed_days = 0` 的重复复习（同刻、显式零间隔）
// 是**合法样本**——API.md §6 `retention_curve` 一节明写「同刻重复复习的零间隔
// 有效」，`review_interval` 也真的把 `Some(0.0)` 推进了 samples。但它随后被
// 归进桶 0，而桶 0 的下界是 `width * 0 = 0`、上界是 `width * 1`，于是
//
//   * 该样本**没有**、也无法被任何区间标签包含（除极小的 width 外 `0 < lower`）；
//   * 桶 0 的标签上界 `width` 声称覆盖 `[0, width)`，却只统计了零间隔样本，
//     把真正落在 `(0, width)` 里的样本排除在外——读数恰好相反；
//   * `curve` 的「→ 曲线单调不增，符合遗忘规律」判据因此建在一串错位区间上。
//
// 根因：归桶的乘法边界搜索是 `while bi > 0 && iv < width·bi { bi -= 1 }`，
// 下界是 `bi > 0`，所以 `iv == 0` 永远停在 `bi == 0`，与「最大 k 使
// `iv >= width·k`」这条文档语义（k 对 iv=0 应为 0……而桶 0 的上界是 width）
// 之间的缺口没人补：iv = 0 不属于 `[0, width)` 里的任何位置。
//
// 修复：零间隔样本单独成桶，标签 `[0, 0]`——与既有「全部样本为零 ⇒ 一个
// `[0, 0]` 桶」的约定同形，且不再谎称覆盖 `(0, width)`。
//
// 判据（双向）：
//   - 有零样本 ⇒ 必须存在一行动 `lo == hi == 0`，且该行的样本数与保持率
//     **只**由零间隔样本决定；
//   - 无零样本 ⇒ 不得存在 `lo == hi` 的行（不许为了修这个 bug 把正常桶压扁）。
// ============================================================================

///|
/// 一张卡：首条零间隔（无前驱，不计样本）+ 一条同刻重复（显式零间隔，计样本）
/// + 一条正间隔；另一张卡提供最大值。零间隔样本恰好 1 条。
fn rc22_zero_gap_log() -> ReviewLog {
  let log = ReviewLog::new()
  // c1：首条 elapsed=0 且无前驱 ⇒ 不计样本
  log.push(ReviewEvent::new("c1", 0L, 0L, Grade::Good, 0.0))
  // c1：同刻重复复习，显式零间隔 ⇒ 计一个 Some(0.0) 样本
  log.push(ReviewEvent::new("c1", 0L, 0L, Grade::Again, 0.0))
  // c1：正间隔样本 10 天（Again，便于区分保持率来源）
  log.push(ReviewEvent::new("c1", 864000L, 0L, Grade::Again, 10.0))
  // c2：单独提供最大值
  log.push(ReviewEvent::new("c2", 0L, 0L, Grade::Good, 20.0))
  log
}

///|
test "RC-22-1: 零间隔样本必须独占一桶，且保持率只由零间隔样本决定" {
  let curve = retention_curve(rc22_zero_gap_log(), 4)
  println("curve=" + curve.to_string())
  // 双向判据第一半：存在 lo == hi == 0 的行
  let mut zero_row : (Double, Double, Double)? = None
  for row in curve {
    if row.0 == 0.0 && row.1 == 0.0 {
      zero_row = Some(row)
    }
  }
  match zero_row {
    Some(row) =>
      // 该行只装那 1 个零间隔样本；(1 个 Again) ⇒ 保持率 0
      assert_eq(row.2, 0.0)
    None =>
      fail(
        "零间隔样本没有独占一桶：[0, 0] 行缺失，样本被塞进了 [0, width) 的桶",
      )
  }
  // 正间隔样本一个都不能少：桶外样本总数应为 2（10 天、20 天）
  let mut non_zero_samples = 0
  for row in curve {
    if row.1 > 0.0 {
      non_zero_samples = non_zero_samples + 1
    }
  }
  assert_eq(non_zero_samples, 2)
}

///|
test "RC-22-1b: 桶 0 不再把零间隔样本算进 (0, width) 那一档的分子分母" {
  let curve = retention_curve(rc22_zero_gap_log(), 4)
  println("curve=" + curve.to_string())
  // 修复前：[(0.0, 5.0, 0.0), (10.0, 15.0, 0.0), (15.0, 20.0, 1.0)]
  //   桶 0 混装了那 1 个零间隔样本（Again ⇒ 保持率 0），却顶着 `[0, 5)` 的名头。
  // 修复后：[(0.0, 0.0, 0.0), (10.0, 15.0, 0.0), (15.0, 20.0, 1.0)]
  //   零间隔自成一档；本日志在 `(0, 5)` 里没有样本，所以桶 0 这一行消失。
  for row in curve {
    if row.0 == 0.0 {
      assert_eq(row.1, 0.0)
      assert_eq(row.2, 0.0)
    }
  }
  // 且每个正样本都真被某行区间包含（末行闭区间）
  for iv in [10.0, 20.0] {
    let mut covered = false
    for i, row in curve {
      let last = i == curve.length() - 1
      if row.0 <= iv && (iv < row.1 || (last && iv == row.1)) {
        covered = true
      }
    }
    assert_true(covered)
  }
}

///|
test "RC-22-1c: 无零间隔样本时不得出现 lo == hi 的退化桶" {
  let log = ReviewLog::new()
  log.push(ReviewEvent::new("c1", 0L, 0L, Grade::Good, 5.0))
  log.push(ReviewEvent::new("c1", 86400L, 0L, Grade::Good, 10.0))
  log.push(ReviewEvent::new("c1", 259200L, 0L, Grade::Good, 20.0))
  let curve = retention_curve(log, 4)
  println("curve=" + curve.to_string())
  for row in curve {
    assert_true(row.0 < row.1)
  }
}

///|
test "RC-22-1d: 全部样本为零时仍是单个 [0, 0] 桶（既有约定不变）" {
  let log = ReviewLog::new()
  log.push(ReviewEvent::new("c1", 0L, 0L, Grade::Good, 0.0))
  log.push(ReviewEvent::new("c1", 0L, 0L, Grade::Good, 0.0))
  let curve = retention_curve(log, 4)
  println("curve=" + curve.to_string())
  assert_eq(curve.length(), 1)
  assert_eq(curve[0].0, 0.0)
  assert_eq(curve[0].1, 0.0)
  assert_eq(curve[0].2, 1.0)
}
