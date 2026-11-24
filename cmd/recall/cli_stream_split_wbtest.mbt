///|
/// 审计回归（第十七轮 F1，2026-11-24）：**stdout 只放数据，诊断走 stderr**。
///
/// 现象：本工具的主用法是
///
///     recall replay --log x.jsonl --json > out.json
///
/// 修前实测（windows，`moon run cmd/recall`，日志第 2 行是坏 JSON）：
///
///     > out.json     ← 里面躺着 "数据错误: 第 2 行解析失败 — 不是合法 JSON"
///     > err.txt      ← 空
///     exit=1
///
/// 即：**机器可读的输出文件被诊断信息写脏**，而 stderr 干净得反常。`--anki`
/// 侧同一类问题——`--json --anki` 同给时的提示行原本挤在 TSV 正文前面。
///
/// 根因：所有输出共用一个 `println`，诊断与数据没有分道。
/// 修法：`main.mbt` 的「输出通道」一节——`emit`（stdout，数据）与 `diag`
/// （stderr，诊断）两个出口，接收端用 `Ref` 暴露给测试替换。
///
/// 这组用例不碰磁盘：错误路径用「不存在的日志文件」，成功路径用不需要 `--log`
/// 的 `simulate`。端到端（真重定向）的实测记录写在 API.md 第 7 节与
/// `audit/2026-11-24/recall/REPORT.md`。

///|
/// 换掉两个输出接收端跑一次 `f`，返回 (退出码, stdout 全文, stderr 全文)。
fn capture_streams(f : () -> Int32) -> (Int32, String, String) {
  let saved_out = stdout_sink.val
  let saved_err = stderr_sink.val
  let out : Array[String] = []
  let err : Array[String] = []
  stdout_sink.val = fn(msg) { out.push(msg) }
  stderr_sink.val = fn(msg) { err.push(msg) }
  let code = f()
  stdout_sink.val = saved_out
  stderr_sink.val = saved_err
  (code, out.join("\n"), err.join("\n"))
}

///|
test "cli stream split: --json 遇到坏日志时 stdout 一个字节都不写" {
  // 不存在的文件走 read_text → None → 「数据错误: 无法读取文件」，与坏 JSON
  // 行共用同一条诊断出口（load_log 的两个分支）。
  let args = parse_args(["--log", "__no_such_log__.jsonl", "--json"])
  let (code, out, err) = capture_streams(fn() { cmd_replay(args) })
  assert_eq(code, 1)
  inspect(out, content="")
  assert_true(err.contains("数据错误: 无法读取文件"))
}

///|
test "cli stream split: 用法错误只进 stderr" {
  let (code, out, err) = capture_streams(fn() { cmd_stats(parse_args([])) })
  assert_eq(code, 2)
  inspect(out, content="")
  assert_true(err.contains("用法错误: stats 需要 --log FILE"))
  let (code2, out2, err2) = capture_streams(fn() { cmd_curve(parse_args([])) })
  assert_eq(code2, 2)
  inspect(out2, content="")
  assert_true(err2.contains("用法错误: curve 需要 --log FILE"))
  // usage_error 连用法正文一起进 stderr：正文在这里是错误报告的一部分，
  // 不是"数据"。
  let (_, out3, err3) = capture_streams(fn() {
    usage_error("未知子命令 nope")
    2
  })
  inspect(out3, content="")
  assert_true(err3.contains("用法错误: 未知子命令 nope"))
  assert_true(
    err3.contains("退出码: 0 成功 / 1 数据错误 / 2 用法错误"),
  )
}

///|
test "cli stream split: 量级守卫的拒绝理由只进 stderr" {
  // 守卫在读日志之前就返回（cmd_curve 的顺序：--log 必填 → --buckets 解析 →
  // 上界守卫 → load_log），所以这里不需要真日志。
  let args = parse_args(["--log", "__ignored__.jsonl", "--buckets", "20000"])
  let (code, out, err) = capture_streams(fn() { cmd_curve(args) })
  assert_eq(code, 2)
  inspect(out, content="")
  assert_true(err.contains("--buckets 必须 <= 10000"))
}

///|
test "cli stream split: 成功路径不往 stderr 写任何东西" {
  let args = parse_args([
    "--scheduler", "fsrs", "--days", "3", "--new-per-day", "2",
  ])
  let (code, out, err) = capture_streams(fn() { cmd_simulate(args) })
  assert_eq(code, 0)
  inspect(err, content="")
  // 数据确实在 stdout：报表首行与摘要行都在
  assert_true(out.contains("模拟: fsrs / realistic 策略"))
  assert_true(out.contains("最终积压:"))
}

///|
test "cli stream split: 重定向后的 JSON 只含数据（模拟 > out.json）" {
  // 直接把 emit 的产物拼起来，模拟 `> out.json` 得到的内容：必须仍是
  // 一个从 `{` 开始、以 `}` 收尾的 JSON——诊断不在其中。
  let args = parse_args(["--log", "__no_such_log__.jsonl", "--json"])
  let (code, out, err) = capture_streams(fn() { cmd_replay(args) })
  assert_eq(code, 1)
  assert_false(out.contains("数据错误"))
  assert_true(err.contains("数据错误"))
}
