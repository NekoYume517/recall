// 回归测试：CLI 数值参数的守卫与提示逻辑（对抗性审计 P3 批）。
//
// 覆盖四个独立缺陷：
//   R1 --retention 越界时打印值 ≠ 生效值（scheduler 夹到 [0.5,0.99]，
//      但 CLI 原样打印用户输入，用户以为 0.3 生效了）；
//   R2 --days 只有 <0 检查，无上限（--days 2000000000 会跑出天文成本）；
//   R3 --seed 用 Int32 解析再 to_int64，Int64 范围的种子被误报非法；
//   R4 replay --anki --json 同给时 --json 被静默忽略。
//
// 2026-10-27 增补（RC-1）：`--key=value` 形式必须与 `--key value` 等价。
// 旧实现只按空格切分，`--days=10` 整体落进 flags（键值一起丢失），
// 参数静默回退默认值且退出码 0 —— 用户拿到一个自己没要求的实验。

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

// ---------------------------------------------------------------------------
// RC-1（2026-10-27）：`--key=value` 等价于 `--key value`
//
// 现象：旧 parse_args 只认空格形式。`--days=10` 里 body = "days=10"，
//   下一项不以 `--` 开头时被当作「值」收进 params["days=10"]，
//   `Args::get("days", …)` 永不命中，参数静默回退默认值——
//   `simulate --days=10` 实跑 90 天、`replay --scheduler=sm2` 实跑 fsrs，
//   两者退出码都是 0。
// 契约：usage 文本与 README 把 --days / --scheduler 列为可配置项；
//   同一意图写成等号形式必须给出同一结果（或明确报用法错误），
//   不允许「既没生效、也不报错」。
// ---------------------------------------------------------------------------

///|
test "RC-1: --key=value 切分后键与值都保留" {
  let args = parse_args(["--days=10", "--new-per-day=2"])
  assert_eq(args.get("days", ""), "10")
  assert_eq(args.get("new-per-day", ""), "2")
}

///|
test "RC-1: --scheduler=sm2 让调度器名真正被读到" {
  let args = parse_args(["--log=x.jsonl", "--scheduler=sm2"])
  assert_eq(args.get("scheduler", ""), "sm2")
  // 未提供 scheduler 时才回退默认
  let args2 = parse_args(["--log=x.jsonl"])
  assert_eq(args2.get("scheduler", "fsrs"), "fsrs")
}

///|
test "RC-1: 等号形式与空格形式解析结果逐键相同" {
  let eq = parse_args(["--days=10", "--new-per-day=2", "--review-limit=5"])
  let sp = parse_args([
    "--days", "10", "--new-per-day", "2", "--review-limit", "5",
  ])
  assert_eq(eq.get("days", ""), sp.get("days", ""))
  assert_eq(eq.get("new-per-day", ""), sp.get("new-per-day", ""))
  assert_eq(eq.get("review-limit", ""), sp.get("review-limit", ""))
}

///|
test "RC-1: 纯 --flag（无等号）仍记为布尔 flag" {
  let args = parse_args(["--json", "--anki"])
  assert_true(args.has("json"))
  assert_true(args.has("anki"))
  assert_eq(args.params.length(), 0)
}

///|
test "RC-1: 带等号的 token 不再整体落进 flag 键名" {
  let args = parse_args(["--days=10"])
  // 旧实现的症状：flags 里出现 "days=10"（键值一起被当成 flag 名）
  assert_eq(args.flags.get("days=10"), None)
  assert_eq(args.flags.get("days"), None)
  assert_eq(args.get_opt("days"), Some("10"))
}

///|
test "RC-1: 值中含等号时只按第一个等号切分" {
  let args = parse_args(["--log=a=b.jsonl"])
  assert_eq(args.get("log", ""), "a=b.jsonl")
}

///|
test "RC-1: 等号形式重复给同一参数时后者胜出（last-wins，与空格形式一致）" {
  let eq = parse_args(["--days=10", "--days=20"])
  let sp = parse_args(["--days", "10", "--days", "20"])
  assert_eq(eq.get("days", ""), "20")
  assert_eq(sp.get("days", ""), "20")
  assert_eq(eq.get("days", ""), sp.get("days", ""))
}

///|
test "RC-1: --days= 空值是用法错误而非默认 90 天" {
  // 空值必须能被调用方识别为「提供了但非法」：
  // get_opt 返回 Some("")，由 parse_int_loose("") = None 触发 exit 2。
  let args = parse_args(["--days="])
  assert_eq(args.get_opt("days"), Some(""))
  assert_eq(parse_int_loose(""), None)
}

// ---------------------------------------------------------------------------
// RC-5（2026-10-27）：parse_double_loose 必须像它的兄弟解析器一样防溢出
//
// 现象：`--retention` 走 parse_double_loose。其整数累加
// `acc = acc * 10 + dg` 用 Int64 承载但**没有溢出预检**，超长数字静默回绕；
// 随后小数部分照常拼上，于是回绕后的整数 + 用户的小数位构成一个
// "看起来合法"的值：
//   18446744073709551616.7  (= 2^64 + 0.7)            → 0.70
//   18446744073709551616.5  (= 2^64 + 0.5)            → 0.50
//   36893488147419103232.9  (= 2*2^64 + 0.9)          → 0.90
//   55340232221128654848.8  (= 3*2^64 + 0.8)          → 0.80
// 用户拿到的是一个无人察觉的错误目标保持率（间隔倍率直接跟着它变）。
//
// 契约：同文件的 parse_int_loose 与 parse_int64_loose 都写了显式溢出预检
// （`acc > 2147483648L` / `acc > (limit - dg)/10L`），注释明确"越界返回
// None …… 超长窗口静默当成短窗口跑完"。同类大数解析必须同等严格。
// ---------------------------------------------------------------------------

///|
test "RC-5: parse_double_loose 拒绝 2^64+0.7（不再回绕成 0.7）" {
  assert_eq(parse_double_loose("18446744073709551616.7"), None)
}

///|
test "RC-5: parse_double_loose 拒绝 2^64+0.5" {
  assert_eq(parse_double_loose("18446744073709551616.5"), None)
}

///|
test "RC-5: parse_double_loose 拒绝 2*2^64+0.9" {
  assert_eq(parse_double_loose("36893488147419103232.9"), None)
}

///|
test "RC-5: parse_double_loose 拒绝 3*2^64+0.8" {
  assert_eq(parse_double_loose("55340232221128654848.8"), None)
}

///|
test "RC-5: parse_double_loose 拒绝超长纯整数串" {
  assert_eq(parse_double_loose("99999999999999999999"), None)
  assert_eq(parse_double_loose("12345678901234567890"), None)
}

///|
test "RC-5: 合法的小数/整数照常解析（防过度收紧）" {
  assert_eq(parse_double_loose("0.9"), Some(0.9))
  assert_eq(parse_double_loose("1"), Some(1.0))
  assert_eq(parse_double_loose("-0.25"), Some(-0.25))
  assert_eq(parse_double_loose("+2."), Some(2.0))
  assert_eq(parse_double_loose("0.995"), Some(0.995))
  assert_eq(parse_double_loose("36500"), Some(36500.0))
  assert_eq(parse_double_loose("1000000.5"), Some(1000000.5))
}

///|
test "RC-5: 与兄弟解析器同一套严格性" {
  // 同一串数字，整数解析器拒绝的，浮点解析器也必须拒绝
  for
    s in [
      "18446744073709551617", "99999999999999999999", "12345678901234567890",
    ] {
    assert_eq(parse_int64_loose(s), None)
    assert_eq(parse_double_loose(s), None)
  }
}
