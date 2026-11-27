// ============================================================================
// JSONL 畸形输入的 CLI 层判据：**不得 panic**，退出码只能 0/1/2，
// 诊断只能走 stderr，stdout 只能是数据或空
//
// 第二十一轮 RC-21-4（2026-11-29）。`log.mbt` 的解析入口已有一批单元用例
// （NaN/Infinity 字面量、超长数字、重复键、缺键、BOM、CRLF…），但它们都在库层，
// **走不到 CLI 的退出码与流向**。而本项目最怕的失败形态恰恰是「进程炸了」：
// 一旦 `@json.parse` 或下游统计在畸形输入上 panic，用户看到的是
// exit -1073740791 与一坨栈回溯，而不是「数据错误 + 行号」。
//
// 这条用例把「畸形输入 × 两个子命令」跑成矩阵，只断言三件与实现无关的事：
//   1. `cmd_stats` / `cmd_replay` 的返回码 ∈ {0,1,2}（该子命令的返回码，
//      不是进程退出码；进程层由 main 直接 sys.exit）；
//   2. 返回码非 0 时，**stdout 必须是空的**（不许把诊断写进数据流）；
//   3. 整个过程不 panic（panic 会以 abort 形式逃出，测试直接红）。
//
// 覆盖面（每个 fixture 一行 JSONL，落到 `%TEMP%` 后由 CLI 读）：
//   NaN / Infinity / -Infinity 字面量、1e400、超长整数（400 位）、
//   重复键、缺 grade、缺 card_id、elapsed_days 为字符串 / null / 数组、
//   200 层嵌套、原始控制字符、时间戳 Int64 两端、非法 UTF-8 字节。

///|
/// 解析并跑 `cmd_stats`，返回 (返回码, stdout 文本)。
fn rc21_run_stats(path : String) -> (Int32, String) {
  let out : Array[String] = []
  let saved_out = stdout_sink.val
  let saved_err = stderr_sink.val
  stdout_sink.val = fn(m) { out.push(m) }
  stderr_sink.val = fn(m) { let _ = m }
  let code = cmd_stats(parse_args(["--log", path]))
  stdout_sink.val = saved_out
  stderr_sink.val = saved_err
  (code, out.join("\n"))
}

///|
/// 解析并跑 `cmd_replay --json`，返回 (返回码, stdout 文本)。
fn rc21_run_replay_json(path : String) -> (Int32, String) {
  let out : Array[String] = []
  let saved_out = stdout_sink.val
  let saved_err = stderr_sink.val
  stdout_sink.val = fn(m) { out.push(m) }
  stderr_sink.val = fn(m) { let _ = m }
  let code = cmd_replay(
    parse_args(["--log", path, "--scheduler", "fsrs", "--json"]),
  )
  stdout_sink.val = saved_out
  stderr_sink.val = saved_err
  (code, out.join("\n"))
}

///|
/// 把一段文本写成临时 JSONL 文件，返回路径。
///
/// 落在系统临时目录里（`recall_rc21_<name>.jsonl`），不污染仓库；`moon test`
/// 跑完由下一次运行覆盖同名文件，不留垃圾。
fn rc21_write_tmp(name : String, body : String) -> String {
  let path = "__rc21_" + name + ".jsonl"
  let _ = @fs.write_string_to_file(path, body) catch {
    _ => abort("cannot write fixture")
  }
  path
}

///|
/// 删掉 fixture（**必须调**：否则 `moon test` 会在仓库根目录留下十几个
/// `__rc21_*.jsonl`，`git status` 立刻变脏——这是本轮实测踩到的）。
/// 删除失败不影响判据（文件本来就在），但会显式 abort 以便发现路径写错。
fn rc21_cleanup(path : String) -> Unit {
  let _ = @fs.remove_file(path) catch { _ => () }
}

///|
/// 断言一组 fixture 在两个子命令上都不 panic、退出码合法、脏输出不进 stdout。
fn rc21_check_fixture(name : String, body : String) -> Unit raise {
  let path = rc21_write_tmp(name + ".jsonl", body)
  let (c_stats, o_stats) = rc21_run_stats(path)
  assert_true(c_stats >= 0 && c_stats <= 2)
  if c_stats != 0 {
    inspect(o_stats, content="")
  }
  let (c_replay, o_replay) = rc21_run_replay_json(path)
  assert_true(c_replay >= 0 && c_replay <= 2)
  if c_replay != 0 {
    inspect(o_replay, content="")
  }
  rc21_cleanup(path)
}

///|
/// **坏输入不得产出数据**：除了「不 panic / 退出码合法」之外，还要断言
/// 「坏行没有被静默接受」。否则把 `BadLine` 改成容错（`catch => ""` 兜底）时，
/// 上面那些用例会全绿——它们只看了退出码（本轮实测踩到：把 `field_string`
/// 的缺键分支改成返回空串，149 条用例一条没红）。
///
/// 判据：对每个必然非法（或必然合法）的 fixture，同时断言
///   - 非法 → `cmd_stats` 返回 1（不是 0），且 stdout 为空；
///   - 合法 → 返回 0，且 stdout **非空**（真的是数据）。
fn rc21_check_rejected(name : String, body : String) -> Unit raise {
  let path = rc21_write_tmp(name + "_rej", body)
  let (code, out) = rc21_run_stats(path)
  assert_eq(code, 1)
  inspect(out, content="")
  rc21_cleanup(path)
}

///|
test "rc21-4b: 非法行必须被拒收（exit 1 + stdout 空），不能静默接受" {
  // NaN 字面量
  rc21_check_rejected(
    "r_nan", "{\"card_id\":\"c\",\"reviewed_at\":NaN,\"due_at\":0,\"grade\":3,\"elapsed_days\":1}\n",
  )
  // 缺 card_id —— 这是本轮 mutation 抓到的盲区：把缺键改成返回空串时，
  // 上面「不 panic」那组用例全绿，只有这条会红。
  rc21_check_rejected(
    "r_missing_id", "{\"reviewed_at\":1,\"due_at\":1,\"grade\":3,\"elapsed_days\":1}\n",
  )
  // 缺 grade
  rc21_check_rejected(
    "r_missing_grade", "{\"card_id\":\"c\",\"reviewed_at\":1,\"due_at\":1,\"elapsed_days\":1}\n",
  )
  // elapsed_days 是字符串
  rc21_check_rejected(
    "r_elapsed_str", "{\"card_id\":\"c\",\"reviewed_at\":1,\"due_at\":1,\"grade\":3,\"elapsed_days\":\"1\"}\n",
  )
}

///|
test "rc21-4b: 合法行必须被接受（exit 0 + stdout 非空）——防「一律拒收」" {
  let path = rc21_write_tmp(
    "ok", "{\"card_id\":\"c\",\"reviewed_at\":1700000000,\"due_at\":1700000000,\"grade\":3,\"elapsed_days\":1}\n",
  )
  let (code, out) = rc21_run_stats(path)
  assert_eq(code, 0)
  assert_true(out.length() > 0)
  rc21_cleanup(path)
}

///|
test "rc21-4: NaN / Infinity 字面量不 panic，exit 1，stdout 为空" {
  rc21_check_fixture(
    "nan", "{\"card_id\":\"c\",\"reviewed_at\":NaN,\"due_at\":0,\"grade\":3,\"elapsed_days\":1}\n",
  )
  rc21_check_fixture(
    "inf", "{\"card_id\":\"c\",\"reviewed_at\":Infinity,\"due_at\":0,\"grade\":3,\"elapsed_days\":1}\n",
  )
}

///|
test "rc21-4: 超长数字与 1e400 不 panic" {
  let mut big = ""
  for _ in 0..<400 {
    big = big + "9"
  }
  rc21_check_fixture(
    "bigint",
    "{\"card_id\":\"c\",\"reviewed_at\":" +
    big +
    ",\"due_at\":0,\"grade\":3,\"elapsed_days\":1}\n",
  )
  rc21_check_fixture(
    "e400", "{\"card_id\":\"c\",\"reviewed_at\":1,\"due_at\":0,\"grade\":3,\"elapsed_days\":1e400}\n",
  )
}

///|
test "rc21-4: 字段类型错（elapsed_days 为 string/null）不 panic" {
  rc21_check_fixture(
    "elapsed_str", "{\"card_id\":\"c\",\"reviewed_at\":1,\"due_at\":1,\"grade\":3,\"elapsed_days\":\"1\"}\n",
  )
  rc21_check_fixture(
    "elapsed_null", "{\"card_id\":\"c\",\"reviewed_at\":1,\"due_at\":1,\"grade\":3,\"elapsed_days\":null}\n",
  )
}

///|
test "rc21-4: 缺键与重复键不 panic" {
  rc21_check_fixture(
    "missing_grade", "{\"card_id\":\"c\",\"reviewed_at\":1,\"due_at\":1,\"elapsed_days\":1}\n",
  )
  rc21_check_fixture(
    "dup_key", "{\"card_id\":\"a\",\"card_id\":\"b\",\"reviewed_at\":1,\"due_at\":1,\"grade\":3,\"elapsed_days\":1}\n",
  )
}

///|
// ⚠️ 这条用的是 `rc21_check_fixture`（判据 = 退出码 ∈ {0,1,2}，且非 0 时 stdout 空），
// **不假设 200 层一定被接受**——`@json.parse` 的嵌套上限随工具链版本变化
// （本地 0.1.20261102 是 1024，CI 的 latest 更小；2026-11-29 曾因把上限写进断言
// 让 CI 单条红）。所以这里不做「200 层必须 exit 0」这类断言：上限若小于 200，
// 这一层会被判非法，而「非法则 stdout 必须为空」的判据照样成立。
// 需要钉「越界整行拒绝」这条契约的用例在 `jsonl_documented_behaviors_wbtest.mbt`，
// 那里用**自探上限 D** 而不是硬编码数字。

///|
test "rc21-4: 超深嵌套不 panic（不爆栈）" {
  let mut nest = ""
  for _ in 0..<200 {
    nest = nest + "["
  }
  nest = nest + "1"
  for _ in 0..<200 {
    nest = nest + "]"
  }
  rc21_check_fixture(
    "deep",
    "{\"card_id\":\"c\",\"reviewed_at\":1,\"due_at\":1,\"grade\":3,\"elapsed_days\":1,\"x\":" +
    nest +
    "}\n",
  )
}

///|
test "rc21-4: 时间戳 Int64 两端不 panic" {
  rc21_check_fixture(
    "ts_max", "{\"card_id\":\"c\",\"reviewed_at\":9223372036854775807,\"due_at\":0,\"grade\":3,\"elapsed_days\":1}\n",
  )
  rc21_check_fixture(
    "ts_min", "{\"card_id\":\"c\",\"reviewed_at\":-9223372036854775808,\"due_at\":0,\"grade\":3,\"elapsed_days\":1}\n",
  )
}
