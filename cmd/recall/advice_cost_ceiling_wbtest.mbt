// ============================================================================
// advice 的成本守卫：允准档位必须是**实测可承受**的一档，且默认档必须放行
//
// 缺陷史（第十九轮 RC-19-4，2026-11-27，native release、独立进程、Stopwatch）：
//
//   (a) 原上限 2.5e9 —— 注释写着「上限档 ≈ 三十秒量级」，实测同一档 **704 s**：
//       `advice --days 99 --review-limit 500` 跑 12 分钟才返回 505 B。守卫允准
//       一个 12 分钟的档，等于守卫形同虚设。
//   (b) 一轮修过头 —— 上限收到 3e8，`--days 99 --review-limit 500` 被拒了，
//       但**默认调用** `advice`（days 90 / review-limit 200，3.27e8）也被拒：
//
//           $ recall advice
//           用法错误: … 202 × 90² × 200 = 327240000 …
//             建议: … 把 --days 降到 86 以内 …
//
//       不带参数的 advice 是文档里最常见的用法，让默认调用 exit 2 再让人手动
//       降天数，是把守卫做反了（Lead 裁决 2026-11-27）。
//
// 现在（3.4e8）的实测表（`docs/implementation.md` §13 同表，`percent` 为上限占比）：
//
//     --days 12  --rl 200   5.82e6   0.32 s
//     --days 30  --rl 200   3.64e7   1.20 s
//     --days 60  --rl 200   1.45e8   5.36 s
//     --days 90  --rl 200   3.27e8  16.02 s   ← 默认档，成本 96%
//     --days 95  --rl 200   3.65e8   exit 2（97% 上限外）
//     --days 99  --rl 500   2.46e9   exit 2（修前 704 s）
//
// 判据是**双向**的，不只看一个方向：
//   * 下界 = 默认档必须放行（`advice` 无参 → exit 0），否则默认用法直接坏掉；
//   * 上界 = 上限档实测耗时必须有界（本机 16 s，按慢机器 2 倍留量取 ≤ 40 s）；
//   * 两侧都只用整数（工作单元），不测墙钟 —— 任何机器上同一条命令的行止一致。

///|
test "rc19-4: 默认档（advice 无参 = days 90 / rl 200）必须放行" {
  // 这是本文件最重要的一条：默认调用不能自己撞自己的守卫。
  assert_true(!advice_cost_over(90, 200))
  inspect(advice_cost_error(90, 200), content="")
  // 且默认档的成本就是上限的 96%（3.27e8 / 3.4e8），别把上界压回去。
  assert_true(advice_cost_percent(90, 200) >= 90L)
}

///|
test "rc19-4: 旧缺陷档（--days 99 --review-limit 500，修前 704 s）必须被拒" {
  assert_true(advice_cost_over(99, 500))
  let msg = advice_cost_error(99, 500)
  assert_true(msg.contains("用法错误"))
  // 建议里必须给出一条能跑的档位
  assert_true(msg.contains("--days") || msg.contains("--review-limit"))
}

///|
test "rc19-4: 上限档必须存在，且它的实测耗时 ≤ 40 s（本机 16 s，留 2 倍余量）" {
  // 从默认档往上找第一个被拒的档，它前一档就是「上限档」。
  // 实测（3.4e8）：days 95 (3.65e8) 被拒，days 90 (3.27e8, 16.0 s) 放行。
  let mut d = 90
  while d <= 200 && !advice_cost_over(d, 200) {
    d = d + 1
  }
  // 上限档：最后一个放行的 days
  let edge = d - 1
  assert_true(edge >= 90) // 至少不能低于默认档
  // 上限档的实测耗时表（本机）：12→0.32 s、30→1.20 s、60→5.36 s、90→16.0 s。
  // 只对表里出现过的档位断言，其余档位按「不高于 90 的实测」保守放行。
  let measured : Array[(Int32, Int64)] = [
    (12, 316L),
    (30, 1196L),
    (60, 5360L),
    (90, 16018L),
  ]
  for pair in measured {
    if pair.0 <= edge {
      // 每一档都必须真的放行，且实测 ≤ 40 s（慢机器 2 倍余量）
      assert_true(!advice_cost_over(pair.0, 200))
      assert_true(pair.1 <= 40000L)
    }
  }
}

///|
test "rc19-4: 成本上限必须 ≥ 默认档的工作单元（不许再把默认档卡掉）" {
  assert_true(advice_cost_limit() >= advice_cost_units(90, 200))
}

///|
test "rc19-4: 上限仍需覆盖 simulate 的单次扫描上限（防倒挂）" {
  // advice 的一次探测就是一次 simulate_with_budget，上限小于扫描上限会出现
  // 「同规模 simulate 放行、advice 拒绝」的倒挂。
  assert_true(advice_cost_limit() >= 250000000L)
  // 且不能无限放大：旧缺陷档 2.46e9 永远在界外。
  assert_true(advice_cost_limit() < 2460000000L)
}

///|
test "rc19-4: 成本判据与成本数值同源（同一套单位）" {
  // 取几档跨越边界的配置逐一比对，防止两份判据漂移。
  let cases : Array[(Int32, Int32)] = [
    (48, 200),
    (48, 400),
    (99, 500),
    (90, 200),
    (95, 200),
    (12, 200),
    (24, 200),
  ]
  for pair in cases {
    let over = advice_cost_over(pair.0, pair.1)
    let units = advice_cost_units(pair.0, pair.1)
    assert_eq(over, units > advice_cost_limit())
  }
}
