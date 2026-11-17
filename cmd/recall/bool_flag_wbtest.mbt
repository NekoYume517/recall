///|
/// 审计回归（第十二轮，P3）：布尔参数的显式 `false` 必须真的关掉。
///
/// ## 现象
///
/// `--json` / `--anki` 是布尔参数，读取点只看「键在不在」（`Args::has`）：
///
/// ```
/// $ recall replay --log examples/reviews.jsonl --json=false   → 输出 JSON（exit 0）
/// $ recall replay --log examples/reviews.jsonl --json=0       → 输出 JSON（exit 0）
/// ```
///
/// 显式给了 `false` 却被当成开启，与 usage 自己写的「`--key value` 与
/// `--key=value` 等价」直接冲突，也是三态一致性的又一处：`--days=` 空值会
/// 报错、`--json=false` 却静默变真。
///
/// ## 规则
///
/// `Args::flag` 给出**生效值**：`--x` / `--x=` / `--x=true` / `--x=1` 为真，
/// `--x=false` / `--x=0` 为假，其余非空值按真处理（不额外报错）；
/// `Args::has` 保持「键是否存在」的老语义（未知键检查等仍用它）。

///|
test "boolean flag: --json=false / --json=0 生效值为假" {
  inspect(parse_args(["--json=false"]).flag("json"), content="false")
  inspect(parse_args(["--json=0"]).flag("json"), content="false")
  // 但「键存在」这一点不变（has 的老语义）。
  inspect(parse_args(["--json=false"]).has("json"), content="true")
}

///|
test "boolean flag: 真值形态全部照旧（不误伤既有写法）" {
  inspect(parse_args(["--json"]).flag("json"), content="true")
  inspect(parse_args(["--json="]).flag("json"), content="true")
  inspect(parse_args(["--json=true"]).flag("json"), content="true")
  inspect(parse_args(["--json=1"]).flag("json"), content="true")
  // 未提供 ⇒ 假。
  inspect(parse_args(["--days", "10"]).flag("json"), content="false")
  // anki 同理。
  inspect(parse_args(["--anki=false"]).flag("anki"), content="false")
  inspect(parse_args(["--anki"]).flag("anki"), content="true")
}

///|
test "boolean flag: 与值形参数混用时互不影响" {
  let args = parse_args(["--log", "x.jsonl", "--json=false", "--days=10"])
  inspect(args.flag("json"), content="false")
  inspect(args.get("log", ""), content="x.jsonl")
  inspect(args.get("days", ""), content="10")
}

///|
test "boolean flag: --anki 与 --json 的冲突提示按生效值判断" {
  // 两个都开 → 提示。
  assert_true(
    replay_conflict_hint(
      parse_args(["--anki"]).flag("anki"),
      parse_args(["--json"]).flag("json"),
    ).length() >
    0,
  )
  // json 显式关掉 → 不提示（修复前会提示，因为 has 为真）。
  let a = parse_args(["--anki", "--json=false"])
  inspect(a.flag("anki"), content="true")
  inspect(a.flag("json"), content="false")
  inspect(replay_conflict_hint(a.flag("anki"), a.flag("json")), content="")
}
