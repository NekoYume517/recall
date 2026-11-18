///|
/// 2026-11-19 对抗性审查：`--=value` 是单独 `--` 修复遗漏的等号形态。
///
/// 去掉前导 `--` 后 body 为 `=value`，长度非零；等号切分得到空 key 后，
/// 旧解析器仍写入 params[""]。main 最终打印「未知参数 」（名字空白），
/// 而不是把原始 token 作为非法位置参数展示给用户。
test "empty flag name: --=value 不再进入空字符串参数键" {
  let args = parse_args(["--=5"])
  inspect(args.params.length(), content="0")
  inspect(args.flags.length(), content="0")
  inspect(args.positionals.length(), content="1")
  let msg = positional_args_error("simulate", args)
  assert_true(msg.contains("'--=5'"))
}

///|
test "empty flag name: --= 与后续合法参数互不吃值" {
  let args = parse_args(["--=", "--days", "5"])
  inspect(args.params.length(), content="1")
  inspect(args.get("days", ""), content="5")
  inspect(args.positionals.length(), content="1")
  assert_true(positional_args_error("simulate", args).contains("'--='"))
}

///|
test "empty flag name: 普通等号参数和单独 -- 的既有行为不变" {
  let normal = parse_args(["--days=5"])
  inspect(normal.get("days", ""), content="5")
  inspect(normal.positionals.length(), content="0")
  let dashdash = parse_args(["--", "--days", "5"])
  inspect(dashdash.get("days", ""), content="5")
  inspect(dashdash.positionals.length(), content="1")
}
