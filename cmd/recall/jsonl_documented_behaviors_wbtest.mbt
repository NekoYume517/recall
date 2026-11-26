// ============================================================================
// JSONL 读入口的两条「文档化但此前没写进文档」的行为（第二十一轮裁决追加）
//
// 背景：上一轮的畸形输入矩阵里，`dup_key` 与 `deep_nest` 都返回 exit 0。我当时
// 在报告里写「属文档化行为」——**这是自相矛盾的说法**：文档里根本没有这两条。
// Lead 裁决（2026-11-29）：必须写进 API.md，并给每条配一个断言，让「exit 0 是
// 实现行为」变成「exit 0 是被文档化的行为」。
//
// 实测口径（native release，本轮逐条跑过）：
//
//  1) **重复键：后者覆盖前者。**
//     `{"card_id":"first","card_id":"second",…}` → 输出里只有 `second`。
//     这与主流 JSON 解析器（`JSON.parse` 等）的 last-wins 惯例一致，也与本 CLI
//     对 **参数**的 last-wins 一致（`--log a --log b` 取 b）。**有意为之**。
//
//  2) **深层嵌套：整个字段被丢弃，事件照收；不存在「只丢超出部分」的中间态。**
//     实测分界（对 `,"x":[…[1]…]` 逐层 bisect）：
//
//        depth = 1023  → exit 0，事件被收下（`1 个事件 / 1 张卡片`）
//        depth = 1024  → exit 1，`数据错误: 第 1 行解析失败 — 不是合法 JSON`
//
//     即 `@json.parse` 的嵌套上限是 1024 层（含顶层对象），越界时**不是**把
//     嵌套字段裁掉后继续解析，而是整行判为非法。1023 层以内的嵌套字段本身
//     **完全不参与解析**——它只是被解析器接受、随后被 `obj.get(...)` 忽略，
//     对结果零影响（无嵌套 vs 500 层嵌套的 stats 输出逐字节相同）。
//
// 这两条都不该靠「读者去读实现」才知道，所以：文档写清楚 + 断言钉住。

///|
/// 跑一次 `cmd_stats`，返回 (返回码, stdout)。
fn rc21b_stats(path : String) -> (Int32, String) {
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
fn rc21b_write(name : String, body : String) -> String {
  let path = "__rc21b_" + name + ".jsonl"
  let _ = @fs.write_string_to_file(path, body) catch {
    _ => abort("cannot write fixture")
  }
  path
}

///|
fn rc21b_cleanup(path : String) -> Unit {
  let _ = @fs.remove_file(path) catch { _ => () }
}

///|
test "rc21b: 重复键——后者覆盖前者（last-wins），且事件照收" {
  let body = "{\"card_id\":\"first\",\"card_id\":\"second\",\"reviewed_at\":1700000000," +
    "\"due_at\":1700000000,\"grade\":3,\"elapsed_days\":1}\n"
  let path = rc21b_write("dup", body)
  let (code, out) = rc21b_stats(path)
  assert_eq(code, 0)
  // 输出里出现的是后者；前者整行不该残留
  assert_true(out.contains("second"))
  assert_true(!out.contains("first"))
  rc21b_cleanup(path)
}

///|
test "rc21b: 嵌套 1023 层——嵌套字段被忽略，事件照收（与无嵌套输出逐字节相同）" {
  let head = "{\"card_id\":\"c\",\"reviewed_at\":1700000000,\"due_at\":1700000000," +
    "\"grade\":3,\"elapsed_days\":1"
  let mut nest = ""
  for _ in 0..<1023 {
    nest = nest + "["
  }
  nest = nest + "1"
  for _ in 0..<1023 {
    nest = nest + "]"
  }
  let plain = rc21b_write("plain", head + "}\n")
  let nested = rc21b_write("nest1023", head + ",\"x\":" + nest + "}\n")
  let (c1, o1) = rc21b_stats(plain)
  let (c2, o2) = rc21b_stats(nested)
  assert_eq(c1, 0)
  assert_eq(c2, 0)
  // 去掉首行（文件路径不同）后逐字节相同——嵌套字段对结果零影响
  // split 返回 Iter[StringView]，用它逐行消费（没有索引访问）
  let l2 : Array[StringView] = o2.split("\n").collect()
  let mut idx = 0
  for line in o1.split("\n") {
    if idx > 0 {
      assert_eq(line, l2[idx])
    }
    idx = idx + 1
  }
  assert_eq(idx, l2.length())
  rc21b_cleanup(plain)
  rc21b_cleanup(nested)
}

///|
test "rc21b: 嵌套 1024 层——整行判为非法（不是裁掉超出部分）" {
  let head = "{\"card_id\":\"c\",\"reviewed_at\":1700000000,\"due_at\":1700000000," +
    "\"grade\":3,\"elapsed_days\":1"
  let mut nest = ""
  for _ in 0..<1024 {
    nest = nest + "["
  }
  nest = nest + "1"
  for _ in 0..<1024 {
    nest = nest + "]"
  }
  let path = rc21b_write("nest1024", head + ",\"x\":" + nest + "}\n")
  let (code, out) = rc21b_stats(path)
  assert_eq(code, 1)
  inspect(out, content="")
  rc21b_cleanup(path)
}
