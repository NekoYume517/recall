///|
/// 审计回归（第十九轮 RC-19-1，2026-11-27）：**解析阶段的用法错误必须走 stderr**。
///
/// 现象（修前实测，native release，`cmd /c ... > out 2> err` 逐字节比对）：
///
/// ```
/// recall --bogus          → exit 2，stdout 有「用法错误: 未知子命令 --bogus」+ 整份用法正文，stderr 空
/// recall replay --log     → exit 2，stdout 有「用法错误: 参数 --log 需要一个值…」，stderr 空
/// recall replay -- = 1    → exit 2，stdout 有「用法错误: replay 不接受位置参数…」，stderr 空
/// ```
///
/// 而 `cmd_stats`（缺 --log）与 `cmd_curve`（--buckets 越界）却正确地只写
/// stderr（第十七轮 F1 收敛过）。同一种错误在同一个 CLI 里两种流向：
/// `recall stats --log x --json > out.json` 一旦拼错参数，`out.json` 就被
/// 用法正文写脏，退出码 2 又确实非零——读者只能靠肉眼判断这份文件是诊断
/// 还是数据。
///
/// 根因：`main` 里解析阶段的分支在分派到 `cmd_*` 之前就把用法正文打进去了，
/// 且**先于** `--help` / `help` 的识别：`recall help --bogus 1` 因此打用法
/// 正文并 exit 0（"用户明确给了不认识的参数，却被当成只是想看帮助"）。
///
/// 修法：
///   1. `--help` / `-h` / `help` 提到最前面，带多余 token 一律用法错误；
///   2. 未知子命令、全局多余 token 统一走 `parse_usage_error`（只写 stderr）。
///
/// 本文件锁住"消息构造 → 出口"这一段：`parse_usage_error` 只能落 stderr，
/// 且 `usage_error` 的用法正文也只在 stderr。行为层（真进程重定向）的结论
/// 见 `audit/2026-11-27/recall-evidence/REPORT.md` 的逐条实测记录。

///|
/// 换掉两个输出接收端跑一次 `f`，返回 (stdout 全文, stderr 全文)。
fn rc19_capture(f : () -> Unit) -> (String, String) {
  let saved_out = stdout_sink.val
  let saved_err = stderr_sink.val
  let out : Array[String] = []
  let err : Array[String] = []
  stdout_sink.val = fn(msg) { out.push(msg) }
  stderr_sink.val = fn(msg) { err.push(msg) }
  f()
  stdout_sink.val = saved_out
  stderr_sink.val = saved_err
  (out.join("\n"), err.join("\n"))
}

///|
test "rc19-1: parse_usage_error 只写 stderr，且不附用法正文" {
  let (out, err) = rc19_capture(fn() {
    parse_usage_error("help 不接受参数")
  })
  inspect(out, content="")
  inspect(err, content="用法错误: help 不接受参数")
}

///|
test "rc19-1: usage_error 只写 stderr（含用法正文）" {
  let (out, err) = rc19_capture(fn() { usage_error("未知子命令 zzzz") })
  inspect(out, content="")
  assert_true(err.contains("用法错误: 未知子命令 zzzz"))
  assert_true(
    err.contains("退出码: 0 成功 / 1 数据错误 / 2 用法错误"),
  )
}

///|
/// `help` 的判定被提到所有参数检查之前后，`--help --bogus` 不该再被当成
/// "只是想看帮助"：它带了一个本工具不认识的参数。
test "rc19-1: help 分支的判定先于未知参数检查" {
  let args = parse_args(["--bogus"])
  // `--bogus` 被收进 flags；`help` 分支必须能看见它
  assert_true(args.flags.contains("bogus"))
  assert_eq(args.positionals.length(), 0)
}

///|
test "rc19-1: help 带位置参数时消息可构造" {
  let args = parse_args(["extra"])
  assert_eq(args.positionals.length(), 1)
  let msg = "help 不接受位置参数，多余的 " +
    args.positionals.join(", ")
  assert_true(msg.contains("extra"))
  let (out, err) = rc19_capture(fn() { parse_usage_error(msg) })
  inspect(out, content="")
  assert_true(err.contains("不接受位置参数"))
}
