///|
/// 审计回归（2026-11-13）：`simulate` 的守卫漏掉了 `--days` 的**平方**贡献。
///
/// 旧守卫（2026-11-12，`total_cards_error`）管的是 `--days × --new-per-day`
/// 的乘积 = 卡数。但 `simulate_with` 每天要做两趟**全表扫描**
/// （找 due、统计 backlog），于是扫描工作量是
///
///     Σ_{d<days} states(d) ≈ new_per_day · days² / 2
///
/// 卡数相同的两组参数，扫描量可以差 100 倍：`--days 5000 --new-per-day 20`
/// 与 `--days 100000 --new-per-day 1` **都是 10 万张卡、都通过旧守卫**，
/// 后者实测 **300 s 零字节输出、进程不退出**（`audit/2026-11-13/recall/probe/
/// hang-days100000-n1.*`），而前者 221 s 结束。
///
/// 这与被接受过的 A1（`advice` 的成本模型是「探测次数 × days² × review_limit」）
/// 是同一族：`advice` 那侧按 `days²` 修了，`simulate` 这侧只按 `days` 修，
/// 于是「两轴都合法」的配置依然能挂住。
///
/// 这条用例只测守卫函数本身（纯函数、可精确断言边界）；端到端由 CLI 手工验过，
/// 记录在 `audit/2026-11-13/recall/REPORT.md`。

///|
test "simulate scan guard: 文档与 DEMO 用到的配置全部放行" {
  // README / DEMO 的每条 simulate 都在这里
  inspect(simulate_scan_error(90, 20), content="")
  inspect(simulate_scan_error(60, 20), content="")
  inspect(simulate_scan_error(90, 0), content="")
  inspect(simulate_scan_error(0, 20), content="")
  inspect(simulate_scan_error(1, 100000), content="")
  // 上一轮实测过、必须在边界内放行的两组（10 万张 / 4 万张）
  inspect(simulate_scan_error(5000, 20), content="")
  inspect(simulate_scan_error(2000, 20), content="")
  // 单卡长窗口：实测 6.4 s，也放行
  inspect(simulate_scan_error(20000, 1), content="")
}

///|
test "simulate scan guard: 卡数达标但扫描量超界的配置被拒（含真值）" {
  // 100000 天 × 1 张/天 = 10 万张卡（旧守卫放行），扫描量 4 999 950 000。
  let msg = simulate_scan_error(100000, 1)
  assert_true(msg.length() > 0)
  assert_true(msg.contains("4999950000"))
  assert_true(msg.contains("100000"))
  // 2 万天 × 5 张/天 = 10 万张卡，扫描量 999 950 000，同样超界
  let msg2 = simulate_scan_error(20000, 5)
  assert_true(msg2.contains("999950000"))
}

///|
test "simulate scan guard: 扫描量在 64 位里算，不溢出" {
  // 100000 × 100000 × 99999 ÷ 2 = 4.99995e14：Int32 里早就绕了，Int64 里是真值。
  let msg = simulate_scan_error(100000, 100000)
  assert_true(msg.contains("499995000000000"))
}

///|
test "simulate scan guard: 反算的 --days 上界必须真的能跑，多一天必须被拒" {
  // 固定 --new-per-day 1：反算出上界 d，d 通过、d+1 被拒
  let msg = simulate_scan_error(100000, 1)
  let d = suggested_days_upper_bound(1)
  assert_true(d >= 1)
  inspect(simulate_scan_error(d.to_int(), 1), content="")
  assert_true(simulate_scan_error((d + 1L).to_int(), 1).length() > 0)
  // 拒绝消息里必须出现这个可行值（R-7 同族：建议必须可执行）
  assert_true(msg.contains(d.to_string()))
  // 固定 --new-per-day 20
  let d20 = suggested_days_upper_bound(20)
  inspect(simulate_scan_error(d20.to_int(), 20), content="")
  assert_true(simulate_scan_error((d20 + 1L).to_int(), 20).length() > 0)
  // 边界就是实测过的 10 万张那档：5000 × 20 恰好等于阈值，必须放行
  inspect(simulate_scan_error(5000, 20), content="")
  inspect(simulate_scan_error(5001, 20).length() > 0, content="true")
}

///|
test "simulate scan guard: --new-per-day 0 不产生计算量" {
  inspect(simulate_scan_error(100000, 0), content="")
  // n=0 没有「反算上界」可言，返回 0 作为哨兵（调用方不会把它写进建议）
  inspect(suggested_days_upper_bound(0), content="0")
}
