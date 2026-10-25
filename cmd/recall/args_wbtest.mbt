// 回归测试：CLI 数值参数的守卫与提示逻辑（对抗性审计 P3 批）。
//
// 覆盖四个独立缺陷：
//   R1 --retention 越界时打印值 ≠ 生效值（scheduler 夹到 [0.5,0.99]，
//      但 CLI 原样打印用户输入，用户以为 0.3 生效了）；
//   R2 --days 只有 <0 检查，无上限（--days 2000000000 会跑出天文成本）；
//   R3 --seed 用 Int32 解析再 to_int64，Int64 范围的种子被误报非法；
//   R4 replay --anki --json 同给时 --json 被静默忽略。

///|
test "effective_retention: fsrs 越界值夹到边界并如实返回" {
  // 与 scheduler.mbt 的 Fsrs::with_retention 同一套边界
  assert_eq(effective_retention("fsrs", 0.3), 0.5)
  assert_eq(effective_retention("fsrs", 0.49), 0.5)
  assert_eq(effective_retention("fsrs", 0.5), 0.5)
  assert_eq(effective_retention("fsrs", 0.9), 0.9)
  assert_eq(effective_retention("fsrs", 0.99), 0.99)
  assert_eq(effective_retention("fsrs", 0.995), 0.99)
  // 无效值回退默认 0.9（与 with_retention 一致）
  assert_eq(effective_retention("fsrs", 0.0), 0.9)
  assert_eq(effective_retention("fsrs", 1.0), 0.9)
  assert_eq(effective_retention("fsrs", 5.0), 0.9)
  assert_eq(effective_retention("fsrs", 0.0 / 0.0), 0.9)
}

///|
test "effective_retention: 非 fsrs 调度器没有该参数，原样返回" {
  assert_eq(effective_retention("sm2", 0.3), 0.3)
  assert_eq(effective_retention("leitner", 0.95), 0.95)
}

///|
test "retention_hint: 生效值≠请求值时给出含两个值的提示" {
  let h = retention_hint("fsrs", 0.3)
  assert_true(h.contains("0.3"))
  assert_true(h.contains("0.5"))
  assert_true(h.contains("超出"))
  // 合法值不提示
  assert_eq(retention_hint("fsrs", 0.9), "")
  // 非 fsrs 的提示走另一条既有路径（算法局限），这里不重复提示
  assert_eq(retention_hint("sm2", 0.3), "")
}

///|
test "days_range_error: 负数与超上限都报用法错误" {
  assert_true(days_range_error(-1).contains("非负"))
  assert_eq(days_range_error(0), "")
  assert_eq(days_range_error(90), "")
  assert_eq(days_range_error(100000), "")
  let over = days_range_error(100001)
  assert_true(over.contains("100000"))
  assert_true(over.contains("成本"))
}

///|
test "parse_int64_loose: 接受 Int64 全域，拒绝越界与垃圾" {
  assert_eq(parse_int64_loose("20240101"), Some(20240101L))
  assert_eq(parse_int64_loose("+42"), Some(42L))
  // 幅值 2^63 无法在 Int64 累加器中表达，按越界拒绝（含 -2^63 端点）
  assert_eq(parse_int64_loose("-9223372036854775808"), None)
  assert_eq(
    parse_int64_loose("9223372036854775807"),
    Some(9223372036854775807L),
  )
  assert_eq(
    parse_int64_loose("-9223372036854775807"),
    Some(-9223372036854775807L),
  )
  // Int32 装不下的种子必须可解析（旧实现走 parse_int_loose 会拒绝）
  assert_eq(parse_int64_loose("3000000000"), Some(3000000000L))
  assert_eq(parse_int64_loose("9223372036854775808"), None)
  assert_eq(parse_int64_loose("-9223372036854775809"), None)
  assert_eq(parse_int64_loose(""), None)
  assert_eq(parse_int64_loose("abc"), None)
  assert_eq(parse_int64_loose("1.5"), None)
  assert_eq(parse_int64_loose("--"), None)
}

///|
test "replay_conflict_hint: --anki 与 --json 同给时提示按 --anki 输出" {
  let h = replay_conflict_hint(true, true)
  assert_true(h.contains("--anki"))
  assert_true(h.contains("--json"))
  assert_eq(replay_conflict_hint(true, false), "")
  assert_eq(replay_conflict_hint(false, true), "")
  assert_eq(replay_conflict_hint(false, false), "")
}
