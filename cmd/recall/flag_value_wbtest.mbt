///|
/// 审计回归（2026-11-15 轮）：**值形参数被写成 flag 形态时静默回退默认值**。
///
/// ## 缺陷形态（修复前）
///
///     recall simulate --days --review-limit 200
///
/// `parse_args` 对 `--key value` 的规则是「下一项以 `--` 开头就不当值」，
/// 于是 `--days` 落进 `flags`、`--review-limit` 正常收到 200。而
/// `cmd_simulate` 用 `get_opt("days")` 区分「未提供」（默认 90）与
/// 「提供了但非法」（exit 2）—— flag 形态的 `--days` 恰好被归进前者，
/// **静默跑 90 天默认档并 exit 0**。用户以为模拟的是自己给的窗口，
/// 实际参数整体错了。
///
/// 三态一致性（N-5，2026-11-04 审计确立）：
///   - `--days abc`    → exit 2 ✔
///   - `--days=`       → exit 2 ✔
///   - `--days`（值位置是另一个 flag）→ 修复前 exit 0 + 默认 90 ✘
///
/// 第三种「提供了但不对」的形态不该是静默的。修法与 `Args::has` 的
/// 布尔语义正交：**布尔参数只有 replay 的 --json / --anki**，其余键
/// 以 flag 形态出现即用法错误（消息给可执行写法）。
///
/// ## 修复
///
/// `value_required_keys(sub)` 声明每个子命令「必须带值」的键；
/// `flag_shaped_value_error` 在 main 的未知键检查之后把 flag 形态的
/// 值参数报成用法错误（exit 2）。布尔键不在清单里，`--json` /
/// `--anki` 行为不变；`--key=value` 与 `--key value` 两种合法写法
/// 不受影响。

///|
test "flag-shape: 值形参数单独出现必须报错，而不是静默回退默认值" {
  let args = parse_args(["--days", "--review-limit", "200"])
  // 修复前：days 被收进 flags，days 参数静默回退默认 90
  let err = flag_shaped_value_error("simulate", args)
  inspect(err.contains("--days"), content="true")
  inspect(err.contains("需要一个值"), content="true")
}

///|
test "flag-shape: --days 是最后一个 token（无后续值）同样报错" {
  let args = parse_args(["--scheduler", "fsrs", "--days"])
  let err = flag_shaped_value_error("simulate", args)
  inspect(err.contains("--days"), content="true")
}

///|
test "flag-shape: 多个值形参数同时写成 flag，全部列出" {
  let args = parse_args(["--days", "--new-per-day", "--policy"])
  let err = flag_shaped_value_error("simulate", args)
  inspect(err.contains("--days"), content="true")
  inspect(err.contains("--new-per-day"), content="true")
  inspect(err.contains("--policy"), content="true")
}

///|
test "flag-shape: 布尔参数 --json / --anki 不在值清单里，行为不变" {
  let args = parse_args([
    "--log", "a.jsonl", "--scheduler", "sm2", "--json", "--anki",
  ])
  inspect(flag_shaped_value_error("replay", args), content="")
  inspect(args.has("json"), content="true")
  inspect(args.has("anki"), content="true")
  inspect(args.get("scheduler", ""), content="sm2")
}

///|
test "flag-shape: 合法写法（等号形式 / key value 形式）不受影响" {
  let a1 = parse_args(["--days=10", "--review-limit=0"])
  inspect(flag_shaped_value_error("simulate", a1), content="")
  let a2 = parse_args(["--days", "10", "--review-limit", "0"])
  inspect(flag_shaped_value_error("simulate", a2), content="")
  // 值本身以 -- 开头的合法场景：文件名理论上是调用方的自由，
  // 但 --log 的值以 -- 开头时旧解析器本就收不进来（收进 flags），
  // 这里只锁定值形参数检查不把这类值误报 —— 值在 params 里不触发。
  let a3 = parse_args(["--log", "--weird.jsonl"])
  // "--weird.jsonl" 以 -- 开头 → 被解析成 flag（这是 parse_args 的既有
  // 规则，不是本修复引入的），--log 成了 flag 形态 → 应当报错提示。
  inspect(
    flag_shaped_value_error("replay", a3).contains("--log"),
    content="true",
  )
}

///|
test "flag-shape: 每个子命令的值清单覆盖它实际读取的键" {
  // replay / compare / stats / curve 的全部非布尔键
  inspect(value_required_keys("replay").contains("log"), content="true")
  inspect(value_required_keys("replay").contains("scheduler"), content="true")
  inspect(value_required_keys("replay").contains("json"), content="false")
  inspect(value_required_keys("replay").contains("anki"), content="false")
  inspect(value_required_keys("compare").contains("a"), content="true")
  inspect(value_required_keys("compare").contains("b"), content="true")
  inspect(value_required_keys("stats").contains("log"), content="true")
  inspect(value_required_keys("curve").contains("buckets"), content="true")
  // simulate / advice 的完整键清单（与 main 的 allowed 对齐，布尔键除外）
  inspect(value_required_keys("simulate").length(), content="7")
  inspect(value_required_keys("advice").length(), content="7")
  // 未知子命令不给清单（unknown-key 检查已经拦截）
  inspect(value_required_keys("bogus").length(), content="0")
}
