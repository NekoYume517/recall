// ============================================================================
// 裸 token 出现在**任何位置**都必须报用法错误，不能被吞成上一个 flag 的值
//
// 现象（第二十轮 RC-20-2，2026-11-28）：
//
//     recall replay --json stray --log r.jsonl --scheduler fsrs
//       -> exit 0，正常输出 JSON —— `stray` 成了「--json 的值」，被静默吃掉
//     recall replay --log r.jsonl --scheduler fsrs stray
//       -> exit 2，多余的 'stray'
//
// 同一类错法，只因为裸 token 恰好跟在 flag 后面就得到两种结果。更糟的是
// 「flag 被提升为值形参数」：`--json stray` 之后 `--json` 不再是布尔开关，
// 而是 `params["json"] = "stray"`——`Args::flag` 仍返回 true（非空即真），
// 于是**输出形态没变、错误也没报**，用户以为 `stray` 被接受了。
//
// 根因：`parse_args` 对 `--key` 一律先看「下一个 token 是不是以 -- 开头」，
// 是则当 flag、否则当 key 的**值**；它并不知道哪些键是值形、哪些是纯开关。
// 已知的开关清单（`--json` / `--anki`）在 `main` 里的 `allowed` 表才出现，
// 解析阶段看不见。
//
// 修法：把「纯开关键」清单下沉到解析层（`is_bool_switch(key)`），
// `--json xyz` 里的 `xyz` 不再被当成值，而是落进 positionals → 报用法错误；
// 同时保留 `--json=false` / `--json=1` 这类显式 `=value` 写法（它们走等号分支）。

///|
/// 解析：`--json stray --log x` 里的 `stray` 必须落进 positionals。
test "rc20-2: 开关后面的裸 token 不能成为它的值" {
  let args = parse_args(["--json", "stray", "--log", "x.jsonl"])
  // 开关本身仍是开着
  assert_true(args.flag("json"))
  // 但不再被提升为值形参数
  assert_true(!args.params.contains("json"))
  // 裸 token 被收下，交给 positional_args_error 报错
  assert_eq(args.positionals.length(), 1)
  inspect(args.positionals[0], content="stray")
  let msg = positional_args_error("replay", args)
  assert_true(msg.contains("stray"))
}

///|
test "rc20-2: 开关的显式 =value 写法保持不变" {
  // --json=false / --json=1 走等号分支，仍然是 params，由 Args::flag 判真假
  let off = parse_args(["--json=false", "--log", "x.jsonl"])
  assert_true(!off.flag("json"))
  let on = parse_args(["--json=1", "--log", "x.jsonl"])
  assert_true(on.flag("json"))
}

///|
test "rc20-2: --anki 同族" {
  let args = parse_args(["--anki", "oops", "--log", "x.jsonl"])
  assert_true(args.flag("anki"))
  assert_true(!args.params.contains("anki"))
  assert_eq(args.positionals.length(), 1)
}

///|
test "rc20-2: 值形参数不受影响（--log x 仍收成值）" {
  let args = parse_args(["--log", "x.jsonl", "--scheduler", "fsrs"])
  assert_true(args.params.contains("log"))
  inspect(args.params["log"], content="x.jsonl")
  inspect(args.params["scheduler"], content="fsrs")
  assert_eq(args.positionals.length(), 0)
}
