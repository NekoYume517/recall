// ============================================================================
// advice 的成本守卫必须给出「实测可承受的一档」——它允准的最慢配置不能是分钟级
//
// 现象（第十九轮 RC-19-4，2026-11-27，native release、独立进程、Stopwatch）：
//
//     advice --days 99 --review-limit 500   -> exit 0，704 s（12 分钟），输出 505 B
//     advice --days 48 --review-limit 400   -> exit 0，21.6 s
//     advice --days 48 --review-limit 200   -> exit 0，4.4 s
//     simulate --days 48 --new-per-day 20 --review-limit 400 -> exit 0，0.13 s
//
// 成本守卫 `advice_cost_over` 的判据是 `(hi+2) × days² × hi <= 2.5e9`（工作单元），
// 而它的注释声称「上限档 ≈ 三十秒量级」。实测同一档要 704 s ——**单位换算整体差
// 一个数量级**：2.5e9 工作单元在 advice 这条路径上约合 700 s（≈ 3.6e6 单元/秒，
// 而单个 simulate 路径实测 ≈ 1e8 单元/秒，两者差 28 倍，因为 advice 的每次探测
// 都要重建整份模拟器状态、并且 hi+2 次探测并不总是提前命中）。
//
// 后果和 `--seed` 那轮同族：守卫**允准**一个跑 12 分钟的档，等于守卫形同虚设。
//
// 判据（零噪声、不测墙钟）：把上限降到「实测 ≤ 30 s」的量级，用**工作单元**
// 保证：`advice_cost_units(上限档) <= 3.0e8`。该数由实测反推
// （704 s ↔ 2.5e9 → 30 s ↔ ≈1.07e8，再乘 3 倍余量容纳慢机器 / debug 构建），
// 且判据只看整数，任何机器上同一条命令的行止完全一致。
//
// 修法：`advice_cost_limit()` 单点给出上限，`advice_cost_over` /
// `advice_cost_units` / 提示文案 / 百分比全部读它，不再各写一份 2.5e9。

///|
test "rc19-4: advice 的成本上限落在实测可承受的量级（<= 3e8 工作单元）" {
  assert_true(advice_cost_limit() <= 300000000L)
  // 至少要比 simulate 的单次扫描上限（2.5e8）宽，否则「同规模 advice 比
  // simulate 更容易被拒」又会倒过来变成新缺陷
  assert_true(advice_cost_limit() >= 100000000L)
}

///|
test "rc19-4: --days 99 --review-limit 500 这一档必须被拒（实测 704 s）" {
  assert_true(advice_cost_over(99, 500))
  let msg = advice_cost_error(99, 500)
  assert_true(msg.contains("用法错误"))
  // 建议里必须给出一条能跑的档位
  assert_true(msg.contains("--days") || msg.contains("--review-limit"))
}

///|
test "rc19-4: 30 秒量级的档位仍然放行（--days 48 --review-limit 200，实测 4.4 s）" {
  assert_true(!advice_cost_over(48, 200))
  inspect(advice_cost_error(48, 200), content="")
}

///|
test "rc19-4: 成本判据与成本数值同源（同一套单位）" {
  // 越界的档位：units 超上限，over 也必须是 true；反之亦然。
  // 取几档跨越边界的配置逐一比对，防止两份判据漂移。
  let cases : Array[(Int32, Int32)] = [
    (48, 200),
    (48, 400),
    (99, 500),
    (90, 200),
    (12, 200),
    (24, 200),
  ]
  for pair in cases {
    let over = advice_cost_over(pair.0, pair.1)
    let units = advice_cost_units(pair.0, pair.1)
    assert_eq(over, units > advice_cost_limit())
  }
}
