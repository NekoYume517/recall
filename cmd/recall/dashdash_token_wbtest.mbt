///|
/// 审计回归（第十三轮，P3）：单独的 `--` 被当成「名字为空的参数」。
///
/// ## 现象
///
/// ```
/// recall simulate -- --days 5
/// 用法错误: 未知参数 （simulate 接受: scheduler, days, new-per-day, ...）
/// ```
///
/// 「未知参数」后面是**空的**——用户看不到自己哪里写错了。更糟的是
/// `parse_args` 把 `--` 之后那个不以 `--` 开头的 token **当成这个空键的值
/// 收下**（`-- 5` ⇒ `params[""] = "5"`），于是那个 token 既不会被报成位置
/// 参数，也不会被报成非法值：两种「提供了但不对」的形态（未知键 / 位置参数）
/// 同时被一个空键吃掉。
///
/// ## 根因
///
/// `parse_args` 用 `tok.substring(start=2, end=tok.length())` 取键名，没有
/// 检查键名非空。`--key value` / `--key=value` / `--flag` 三种形态都假定
/// 键名至少一个字符；`--` 单独出现的第四种形态落进「值形」分支。
///
/// ## 修法
///
/// 把 `--`（键名为空）当**位置参数**收下：`main` 里已有的第五种形态
/// （`positional_args_error`）会如实列出多余的 `'--'`，不必新增报错路径。
///
/// 判级 P3（诊断可断言性）：退出码本来就是 2，坏的是「报什么」以及
/// 「紧随其后的 token 被静默当成空键的值」。

///|
test "R13-4: 单独的 -- 不进 params/flags（不产生空键）" {
  let a = parse_args(["--", "5"])
  match a.params.get("") {
    Some(v) => fail("`--` 被当成空键参数，值 = \{v}")
    None => ()
  }
  match a.flags.get("") {
    Some(_) => fail("`--` 被当成空键 flag")
    None => ()
  }
  // 它必须落进位置参数，由既有路径报错。
  inspect(a.positionals.length(), content="2")
  inspect(a.positionals[0], content="--")
  inspect(a.positionals[1], content="5")
}

///|
test "R13-4: 位置参数报错里能看见 '--' 这个 token" {
  let a = parse_args(["--", "200"])
  let msg = positional_args_error("simulate", a)
  assert_true(msg.contains("'--'"))
  assert_true(msg.contains("'200'"))
  // 空键的旧形态（「未知参数 」）不该再出现：报错文本里没有空名字的槽。
  assert_true(!msg.contains("未知参数"))
}

///|
test "R13-4: 合法写法与 `--key=` / flag 形态不受影响（防过度收紧）" {
  let a = parse_args(["--days", "10", "--json", "--buckets=", "--log=x.jsonl"])
  inspect(a.params.get("days").unwrap(), content="10")
  inspect(a.params.get("buckets").unwrap(), content="")
  inspect(a.params.get("log").unwrap(), content="x.jsonl")
  inspect(a.flags.get("json").unwrap(), content="true")
  inspect(a.positionals.length(), content="0")
  // `--` 作为**值**仍然不被接受（「值以 -- 开头就不当值」的固有规则），
  // 此时 `--days` 落进 flags，由既有的 flag 形态守卫报错。
  let b = parse_args(["--days", "--"])
  inspect(b.params.length(), content="0")
  inspect(b.flags.get("days").unwrap(), content="true")
  assert_true(flag_shaped_value_error("simulate", b).contains("--days"))
}
