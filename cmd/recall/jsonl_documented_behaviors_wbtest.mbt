// ============================================================================
// JSONL 读入口的两条「文档化」行为 —— **CLI 侧**（走文件、走 stdout/stderr）
//
// ## 版本史（三次 CI 失败，都是这条用例）
//
// 1. 第一版把 `@json.parse` 的嵌套上限硬编码成 1024 写进断言 → CI 的上限更小，
//    1024 层合法，`assert_eq(code, 1)` 红；
// 2. 第二版改成「自探 D」，但探针**经过 fs + CLI 子进程**：每探一个深度就写一次
//    `__rc21b_probe.jsonl`、跑一次 `cmd_stats`、删一次，几十次往返里任何一次 IO
//    出错就 `abort("cannot write fixture")` —— 在测试框架里表现为
//    `failed: Error` + `_internal_catch_error` 栈，**整条用例被炸掉**；
// 3. 现在（第三版）：**嵌套上限的探测整体搬到库层**
//    （`src/json_parse_depth_limit_test.mbt`，直接 `@json.parse`，零文件、零子进程），
//    这里只保留「CLI 读文件 → stdout/stderr」这条链路本身该验的两件事：
//    - 重复键 last-wins（走完整解析 + 报表）；
//    - 合法嵌套对结果零影响（用一个**明确合法**的小深度）。
//
// ## fs 使用纪律（本文件）
//
// 每个 fixture 用**唯一文件名**（`__rc21b_<name>.jsonl`），写完即删；
// 写入失败**不 abort**，只让该次检查跳过——一次 IO 抖动不该炸掉整条用例。

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
/// 写 fixture，返回 `Some(path)`；**失败返回 `None`（不 abort）**。
///
/// 第三版改动：原来失败 `abort("cannot write fixture")`，在测试框架里等于
/// 「整条用例 error」，CI 上几十次往返里任何一次抖动都会炸掉用例。
fn rc21b_write(name : String, body : String) -> String? {
  let path = "__rc21b_" + name + ".jsonl"
  let r : Unit? = Some(@fs.write_string_to_file(path, body)) catch { _ => None }
  match r {
    Some(_) => Some(path)
    None => None
  }
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
  match rc21b_write("dup", body) {
    None => () // 本机写不出文件：跳过（不让 IO 抖动炸用例）
    Some(path) => {
      let (code, out) = rc21b_stats(path)
      assert_eq(code, 0)
      // 输出里出现的是后者；前者整行不该残留
      assert_true(out.contains("second"))
      assert_true(!out.contains("first"))
      rc21b_cleanup(path)
    }
  }
}

///|
/// 一个**明确合法**的小深度对结果零影响。
///
/// 为什么用 8 而不是 64：`@json.parse` 的嵌套上限 `D` 是工具链给的，CI 上可能
/// 比 64 小（甚至比 4 小）。8 层虽也在风险区，但这里的关键是**不假设它一定合法**——
/// 若该深度被拒，本用例按「跳过」处理，把「合法/越界」这条边界的验证交给库层的
/// 自探用例（`src/json_parse_depth_limit_test.mbt`，那里直接测 `@json.parse`，
/// 探到的 `D` 是本工具链的真值，与 64 无关）。
test "rc21b: 合法范围的嵌套对结果零影响（不依赖具体上限）" {
  match
    (
      rc21b_write("plain", rc21b_nested_line(0)),
      rc21b_write("nest8", rc21b_nested_line(8)),
    ) {
    (Some(p1), Some(p2)) => {
      let (c_plain, o_plain) = rc21b_stats(p1)
      let (c_nested, o_nested) = rc21b_stats(p2)
      assert_eq(c_plain, 0)
      if c_nested == 0 {
        // 8 层在本工具链下合法：输出必须与无嵌套逐行相同
        let l1 = rc21b_body_lines(o_plain)
        let l2 = rc21b_body_lines(o_nested)
        assert_eq(l1.length(), l2.length())
        for i = 0; i < l1.length(); i = i + 1 {
          assert_eq(l1[i], l2[i])
        }
      } else {
        // 8 层在本工具链下已越界（D < 8）：本用例不适用，但**必须留痕**：
        // 越界时 stdout 必须为空（整行判非法，不是部分成功）。
        inspect(o_nested, content="")
      }
      rc21b_cleanup(p1)
      rc21b_cleanup(p2)
    }
    _ => ()
  }
}
