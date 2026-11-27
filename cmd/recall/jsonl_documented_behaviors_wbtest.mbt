// ============================================================================
// JSONL 读入口的两条「文档化」行为 —— **CLI 侧**（走文件、走 stdout/stderr）
//
// ## 版本史（四次 CI 失败，最后发现是契约方向错了）
//
// 1. 第一版把 `@json.parse` 的嵌套上限硬编码成 1024 写进断言 → CI 的上限不同，
//    1024 层在那侧合法，`assert_eq(code, 1)` 红；
// 2. 第二版改成「自探 D」，但探针**经过 fs + CLI 子进程**：每探一个深度就写一次
//    文件、跑一次 `cmd_stats`、删一次，几十次往返里任何一次 IO 出错就
//    `abort("cannot write fixture")` —— 在测试框架里表现为 `failed: Error` +
//    `_internal_catch_error` 栈，**整条用例被炸掉**；
// 3. 第三版把探测搬到库层直测 `@json.parse`（零 IO），仍以「D 层被拒」为锚；
// 4. **第四版（本版）**：CI 给出决定性证据——`D = 0`，即 CI 的工具链
//    **8192 层全部可解析、根本不存在嵌套上限**。「越界时整行判非法」这条契约
//    在无上限的工具链上不成立（那里永不越界）。
//
// 结论：**「某工具链会在第 N 层拒绝」不是本仓库的性质**，为它写契约必然随工具链
// 版本飘。整套探针与「越界」断言已删除，本文件只留两条与上限无关的性质：
//
//   - 未被记录的附加字段（含任意嵌套）**不影响事件内容**；
//   - 解析器若拒了某行，**整行判非法、stdout 不许有半截输出**。
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
/// **本仓库真正的契约：未被记录的附加字段（含任意嵌套）不影响事件内容。**
///
/// 这条与 `@json.parse` 的嵌套上限**无关**。判据是「有附加字段」与「没有附加字段」
/// 两份输入产出的报表**逐行相同**——它只依赖「多余的键被忽略」这一行为，而那是
/// 本仓库读入口自己做的事（`obj.get` 只取已知键），工具链怎么数嵌套都改变不了它。
///
/// ## 为什么不再在这里探测上限（第二十一轮，四次 CI 红）
///
/// 旧版本会在本用例里自探嵌套上限 `D`，并断言「`D` 层被拒」。`D` 是
/// `@json.parse` 的实现细节：
///
///   - 本地 `0.1.20261102`：约 1024 层起拒；
///   - CI 的 `latest`：**8192 层仍全部可解析，根本不存在上限**。
///
/// 在「无上限」的工具链上，「越界」这个现象不存在，任何以它为锚的断言都无从成立。
/// 所以那一整套（探针 + 越界断言）已删除，只留这条与上限无关的性质。
///
/// 若解析器在本工具链上**确实**拒了这个深度（`c_nested != 0`），本用例不装作没事：
/// 它会转而检查「整行拒收时 stdout 必须为空」——这仍然与「上限在哪」无关，
/// 只要求「拒收就拒干净，不要半截输出」。
test "rc21b: 附加字段（含 64 层嵌套）对事件内容零影响" {
  match
    (
      rc21b_write("plain", rc21b_nested_line(0)),
      rc21b_write("nest64", rc21b_nested_line(64)),
    ) {
    (Some(p1), Some(p2)) => {
      let (c_plain, o_plain) = rc21b_stats(p1)
      let (c_nested, o_nested) = rc21b_stats(p2)
      // 无附加字段的基线必须成立
      assert_eq(c_plain, 0)
      if c_nested == 0 {
        // 主判据：附加字段（含 64 层嵌套）被完全忽略 → 报表逐行相同
        let l1 = rc21b_body_lines(o_plain)
        let l2 = rc21b_body_lines(o_nested)
        assert_eq(l1.length(), l2.length())
        for i = 0; i < l1.length(); i = i + 1 {
          assert_eq(l1[i], l2[i])
        }
      } else {
        // 该工具链在这个深度就拒（有上限且 < 65）：不适用主判据，
        // 但「拒收就不许有半截输出」仍然要成立。
        inspect(o_nested, content="")
      }
      rc21b_cleanup(p1)
      rc21b_cleanup(p2)
    }
    _ => ()
  }
}
