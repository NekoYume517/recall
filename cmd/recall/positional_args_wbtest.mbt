///|
/// 审计回归（第十二轮，P3）：裸 token（位置参数）必须报用法错误。
///
/// ## 现象
///
/// ```
/// $ recall simulate 200
/// 参数: 90 天, 每天新增 20 张, …        ← exit 0，用户要的 200 天变成 90 天
/// $ recall simulate --days 10 extra
/// 参数: 10 天, …                        ← exit 0，"extra" 无声消失
/// ```
///
/// ## 为什么是缺陷（不是「文档说位置参数会被忽略」）
///
/// N-5 立的规矩是「提供了但不对必须报错」，已经覆盖四种形态：
///
///     --dys 10        → 未知参数，exit 2
///     --days=         → 空值，exit 2
///     --days abc      → 非法值，exit 2
///     --days --rl 5   → 值形参数的 flag 形态，exit 2
///
/// 裸 token 是第五种，修复前是**静默**的：拼错成 `days=10`（少两个减号）或
/// 多打一个参数，拿到的是一份跑错了的实验结果，退出码 0。与 N-5 当年
/// （`--dys 10` 静默跑默认档）完全同型。

///|
test "positional: 裸 token 被收下并报错，而不是静默忽略" {
  let args = parse_args(["200"])
  inspect(args.positionals.length(), content="1")
  let msg = positional_args_error("simulate", args)
  assert_true(msg.contains("不接受位置参数"))
  assert_true(msg.contains("'200'"))
  assert_true(msg.contains("--key value"))
}

///|
test "positional: 与合法参数混用时也报错，且合法参数照常解析" {
  let args = parse_args(["--days", "10", "extra"])
  inspect(args.get("days", ""), content="10")
  inspect(args.positionals.length(), content="1")
  assert_true(positional_args_error("simulate", args).contains("'extra'"))
}

///|
test "positional: 多个裸 token 全部列出" {
  let args = parse_args(["90", "20", "200"])
  inspect(args.positionals.length(), content="3")
  let msg = positional_args_error("simulate", args)
  assert_true(msg.contains("'90'"))
  assert_true(msg.contains("'20'"))
  assert_true(msg.contains("'200'"))
}

///|
test "positional: 没有裸 token 时是空串（不误伤任何合法写法）" {
  inspect(positional_args_error("simulate", parse_args([])), content="")
  inspect(
    positional_args_error(
      "simulate",
      parse_args(["--days", "10", "--new-per-day=5"]),
    ),
    content="",
  )
  // 值本身以 `-` 开头（负数）仍然是**值**，不是位置参数。
  inspect(
    positional_args_error("simulate", parse_args(["--days", "-5"])),
    content="",
  )
  // 等号形式的负值同理。
  inspect(
    positional_args_error("simulate", parse_args(["--days=-5"])),
    content="",
  )
}

///|
test "positional: 值以 `--` 开头的固有规则不受影响（那走 flag 形态报错）" {
  // `--log --weird.jsonl` 里 `--weird.jsonl` 是**另一个键**，不是位置参数：
  // 这条既有规则（parse_args 的「下一项以 -- 开头就不当值」）不变。
  let args = parse_args(["--log", "--weird.jsonl"])
  inspect(args.positionals.length(), content="0")
  inspect(args.flags.get("log").is_empty(), content="false")
}
