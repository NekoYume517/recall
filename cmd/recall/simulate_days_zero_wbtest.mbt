// 断言补强（2026-11-21 审计，#10）：`simulate --days 0` 的 CLI 端行为。
//
// usage 行 501 写明「simulate 允许 0 = 空结果」，`advice --days 0` 则是
// 「`--days` 必须为正」exit 2。这里把前者钉成 exit 0（库层空结果由
// src/simulate_days_zero_test.mbt 锁）。输出会进测试日志，不做文本匹配——
// 退出码才是契约。

///|
test "simulate --days 0: 三个调度器都 exit 0（空结果不是用法错误）" {
  for sched in ["sm2", "fsrs", "leitner"] {
    let code = cmd_simulate(
      parse_args(["--scheduler", sched, "--days", "0", "--new-per-day", "5"]),
    )
    assert_eq(code, 0)
  }
}

///|
test "advice --days 0: exit 2（窗口必须为正）" {
  let code = cmd_advice(parse_args(["--days", "0"]))
  assert_eq(code, 2)
}
