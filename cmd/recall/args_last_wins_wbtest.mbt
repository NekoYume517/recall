///|
/// 重复参数必须在「--key value / --key=value / --flag」三种形态之间
/// 统一遵守 usage 声明的 last-wins，而不是在 params/flags 两张表里各留一份。
test "last-wins: 较早的缺值形态被后来的合法等号形态覆盖" {
  let args = parse_args(["--days", "--days=1", "--new-per-day=1"])
  assert_eq(args.get_opt("days"), Some("1"))
  assert_eq(args.flags.get("days"), None)
  assert_eq(flag_shaped_value_error("simulate", args), "")
}

///|
test "last-wins: 较早的缺值形态被后来的合法空格形态覆盖" {
  let args = parse_args(["--scheduler", "--scheduler", "sm2"])
  assert_eq(args.get_opt("scheduler"), Some("sm2"))
  assert_eq(args.flags.get("scheduler"), None)
  assert_eq(flag_shaped_value_error("replay", args), "")
}

///|
test "last-wins: 最后一次仍是缺值形态时必须报用法错误" {
  let args = parse_args(["--days=1", "--days"])
  assert_eq(args.get_opt("days"), None)
  assert_eq(args.flags.get("days"), Some(true))
  assert_true(flag_shaped_value_error("simulate", args).contains("--days"))
}

///|
test "last-wins: 最后的合法值覆盖中间缺值与更早合法值" {
  let args = parse_args(["--days=90", "--days", "--days=2"])
  assert_eq(args.get_opt("days"), Some("2"))
  assert_eq(flag_shaped_value_error("simulate", args), "")
}
