// ============================================================================
// JSONL 读入口的两条「文档化但此前没写进文档」的行为（第二十一轮裁决追加）
//
// ⚠️ 2026-11-29 修正（CI run 45916175012 红）：本文件原先硬编码「嵌套上限 =
// 1024 层」并据此断言。**那是把契约建在一个未承诺的实现常量上**：
// `@json.parse` 的嵌套上限随工具链版本变化（本地 0.1.20261102 探得 1024，CI 的
// latest 版本更小），于是 CI 单条红而本地全绿——与 LT40（警告数是工具链因变量）
// 同一类错误。现在改成**自探上限**：先倍增找到第一个非法深度，再二分到精确的
// `D`，然后断言「D 判非法 / D−1 与 64 层合法且与无嵌套零影响」。
// 这样任何工具链的上限都能通过，而「越界是整行拒绝、不是部分成功」这条真契约
// 仍被钉住。
//
// 实测口径：
//
//  1) **重复键：后者覆盖前者。**
//     `{"card_id":"first","card_id":"second",…}` → 输出里只有 `second`。
//     这与主流 JSON 解析器（`JSON.parse` 等）的 last-wins 惯例一致，也与本 CLI
//     对 **参数**的 last-wins 一致（`--log a --log b` 取 b）。**有意为之**。
//
//  2) **深层嵌套：整个字段被丢弃、事件照收；不存在「只丢超出部分」的中间态。**
//     设 `D` = 本工具链下「第一个被拒的嵌套深度」（自探；本地 0.1.20261102 的
//     D = 1024，但**这个数字不进任何断言**）：
//
//        depth <  D  → exit 0，事件被收下（`1 个事件 / 1 张卡片`）
//        depth >= D  → exit 1，`数据错误: 第 1 行解析失败 — 不是合法 JSON`
//
//     即越界时**不是**把嵌套字段裁掉后继续解析，而是整行判为非法。`D` 以内的
//     嵌套字段本身完全不参与解析——只是被解析器接受、随后被 `obj.get(...)`
//     忽略，对结果零影响。
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
/// 造一条「原样事件 + `,"x":<depth 层嵌套>`」的 JSONL 行。`depth == 0` 不带嵌套。
fn rc21b_nested_line(depth : Int32) -> String {
  let head = "{\"card_id\":\"c\",\"reviewed_at\":1700000000,\"due_at\":1700000000," +
    "\"grade\":3,\"elapsed_days\":1"
  if depth <= 0 {
    head + "}\n"
  } else {
    let mut nest = ""
    for _ in 0..<depth {
      nest = nest + "["
    }
    nest = nest + "1"
    for _ in 0..<depth {
      nest = nest + "]"
    }
    head + ",\"x\":" + nest + "}\n"
  }
}

///|
/// 给定嵌套深度跑一次 stats，返回「是否被接受」（exit 0 且 stdout 里含事件）。
fn rc21b_depth_ok(depth : Int32) -> Bool {
  let path = rc21b_write("probe", rc21b_nested_line(depth))
  let (code, out) = rc21b_stats(path)
  rc21b_cleanup(path)
  code == 0 && out.contains("1 个事件")
}

///|
/// **自探**本工具链的嵌套上限：返回「第一个被判非法的深度」`D`。
///
/// 先按 2 的幂倍增找到首个非法深度（上界），再二分到精确值。任何工具链的
/// 上限都能探出来，不依赖硬编码常量。
///
/// 兜底：若一路倍增到 8192 层仍合法，返回 0 表示「未探到上限」。
///
/// ⚠️ 调用方**不能**因此静默通过（本轮 CI 修复时实测踩到的盲区：把实现改成
/// 「越界时剥字段重试」后，任何深度都合法、自探返回 0，若这里当成「不适用」就
/// 会装看不见）。现在的处理是：`d == 0` 时**显式失败**并说明原因——「探不到上限」
/// 本身就是可疑信号（要么实现没有上限，要么它已经不再拒绝超深嵌套）。
fn rc21b_probe_parse_depth_limit() -> Int32 {
  let mut lo = 0 // 已知合法
  let mut hi = 64
  let mut found = false
  while hi <= 8192 {
    if rc21b_depth_ok(hi) {
      lo = hi
      hi = hi + hi
    } else {
      found = true
      break
    }
  }
  if !found {
    return 0
  }
  // 二分 (lo, hi]：lo 合法、hi 非法
  while lo + 1 < hi {
    let mid = lo + (hi - lo) / 2
    if rc21b_depth_ok(mid) {
      lo = mid
    } else {
      hi = mid
    }
  }
  hi
}

///|
/// stats 输出 → 去掉首行（文件路径）后的行数组，用于逐行比对。
fn rc21b_body_lines(text : String) -> Array[StringView] {
  let lines : Array[StringView] = text.split("\n").collect()
  let out : Array[StringView] = []
  let mut i = 0
  for line in lines {
    if i > 0 {
      out.push(line)
    }
    i = i + 1
  }
  out
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
test "rc21b: 明确合法的嵌套深度（64 层）对结果零影响" {
  let plain = rc21b_write("plain", rc21b_nested_line(0))
  let nested = rc21b_write("nest64", rc21b_nested_line(64))
  let (c1, o1) = rc21b_stats(plain)
  let (c2, o2) = rc21b_stats(nested)
  assert_eq(c1, 0)
  assert_eq(c2, 0)
  let l1 = rc21b_body_lines(o1)
  let l2 = rc21b_body_lines(o2)
  assert_eq(l1.length(), l2.length())
  for i = 0; i < l1.length(); i = i + 1 {
    assert_eq(l1[i], l2[i])
  }
  rc21b_cleanup(plain)
  rc21b_cleanup(nested)
}

///|
test "rc21b: 越界嵌套——自探上限 D 判非法、D−1 合法（不裁掉超出部分）" {
  let d = rc21b_probe_parse_depth_limit()
  if d == 0 {
    // 8192 层以内探不到上限 = 可疑信号：要么实现真的没有上限（那「越界整行拒绝」
    // 这条契约就不成立），要么它已不再拒绝超深嵌套（例如退化成「剥字段重试」）。
    // 两种情况都必须红——不允许静默通过。
    abort(
      "自探 8192 层以内未遇到非法嵌套：实现可能已不再拒绝超深嵌套，" +
      "「越界整行判非法」这条契约失去对照物",
    )
  } else {
    // ① D 层（第一个非法深度）：exit 1 且 stdout 为空——整行判非法
    let bad = rc21b_write("nestD", rc21b_nested_line(d))
    let (c_bad, o_bad) = rc21b_stats(bad)
    assert_eq(c_bad, 1)
    inspect(o_bad, content="")
    rc21b_cleanup(bad)
    // ② D−1 层（最后一个合法深度）：exit 0，且与无嵌套输出逐行相同
    let ok = rc21b_write("nestDm1", rc21b_nested_line(d - 1))
    let plain = rc21b_write("plain2", rc21b_nested_line(0))
    let (c_ok, o_ok) = rc21b_stats(ok)
    let (c_plain, o_plain) = rc21b_stats(plain)
    assert_eq(c_ok, 0)
    assert_eq(c_plain, 0)
    let l_ok = rc21b_body_lines(o_ok)
    let l_plain = rc21b_body_lines(o_plain)
    assert_eq(l_ok.length(), l_plain.length())
    for i = 0; i < l_ok.length(); i = i + 1 {
      assert_eq(l_ok[i], l_plain[i])
    }
    rc21b_cleanup(ok)
    rc21b_cleanup(plain)
  }
}
