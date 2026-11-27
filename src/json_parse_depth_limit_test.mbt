// ============================================================================
// `@json.parse` 的嵌套上限 D：库层直测（第三版，CI 修复）
//
// ## 为什么改到这里
//
// 这条探针原来是 **CLI 测试**里的东西：每探一个深度就写一个 fixture 文件、
// 跑一次 `cmd_stats`、再删文件。两次 CI 失败都出在它身上：
//
//   1. 第一版把 D 硬编码成 1024 → CI 的 `@json.parse` 上限更小，1024 层合法，
//      `assert_eq(code, 1)` 红；
//   2. 第二版改成自探，但探针**经过 fs + 子进程**：几十次 `write_string_to_file`
//      里任何一次出错就 `abort("cannot write fixture")`，在测试框架里表现为
//      `failed: Error` + `_internal_catch_error` 栈——**整条用例被炸掉**，
//      而不是断言红。
//
// ## 现在的做法：直接测解析器，不经 fs、不经 CLI
//
// `@json.parse` 对 `src` 包可见（`log.mbt` 就是用它），所以探 D 只需要几十次
// **函数调用**：构造一段 `[[…1…]]` 文本、`@json.parse` 一次、看是否抛错。
// 没有文件、没有子进程、没有 IO 失败路径。
//
// ## 契约（与 D 的数值无关）
//
//   1. `depth < D` 的嵌套**可以被解析**（D 是「第一个解析失败的深度」）；
//   2. `depth >= D` 的嵌套**整体解析失败**——不是把嵌套裁掉后继续。
//
// 第 2 条才是本仓库真正承诺的东西。D 本身是工具链实现常量，**不进任何断言**。

///|
/// 造一段 `depth` 层嵌套的 JSON 文本：`[[…[1]…]]`。`depth == 0` 返回 `"1"`。
fn rc21c_nested_json(depth : Int32) -> String {
  if depth <= 0 {
    return "1"
  }
  let sb = StringBuilder()
  for _ in 0..<depth {
    sb.write_char('[')
  }
  sb.write_char('1')
  for _ in 0..<depth {
    sb.write_char(']')
  }
  sb.to_string()
}

///|
/// 该深度能否被 `@json.parse` 接受。
///
/// 用 `catch` 把「解析失败」收敛成 `false`——**任何**解析异常都算「这个深度不行」，
/// 不会向上冒泡成 `failed: Error`。
fn rc21c_parse_ok(depth : Int32) -> Bool {
  let text = rc21c_nested_json(depth)
  let r : Json? = Some(@json.parse(text)) catch { _ => None }
  match r {
    Some(_) => true
    None => false
  }
}

///|
/// **自探**本工具链的嵌套上限：返回「第一个解析失败的深度」`D`。
///
/// ## 为什么是**线性上扫**，不是「倍增 + 二分」（第四次 CI 修的）
///
/// 上一版从 `hi = 4` 倍增：若 `D <= 4`，**倍增阶段一次都不会成功**，`lo` 保持
/// 初值 0，于是二分区间直接是 `(0, 4]`——「已知可解析的下界」根本没被验证过。
/// 更隐蔽的是：这种写法在 `D` 恰好落在倍增格（4/8/16…）上时结果正确，所以
/// 本机 `D = 1025`（≈2^10）一路绿，**只有换到 `D` 很小的工具链才露**。
///
/// 本机（`0.1.20261102`）实测 `parse_ok(0..8)` 全为 true、`D = 1025`；
/// CI 的解析器在低层的行为可能不同（例如连 1、2 层就拒，甚至 `0` 层就拒），
/// 这两条分支在本机**从未被执行过**——这正是「本地绿、CI 红」的成因。
///
/// 线性上扫把这段逻辑压成一条没有不变量的循环：每一步都直接从 `d = 1` 开始问
/// 「这一层能不能解析」，第一个「不能」就是 `D`。`D <= 8192` 时最多 8192 次
/// 纯函数调用（本机 ~0.1 s），**正确性与 `D` 落在哪无关**，不需要任何前置不变量。
///
/// 前置条件（由调用方断言，不靠推理）：`parse_ok(0) == true`——`0` 层是裸字面量
/// `"1"`，任何正常的 JSON 解析器都该接受它。若连它都失败，说明 `parse_ok` 本身
/// 有问题，此时 `D` 无意义，必须显式失败而不是返回一个错误的数。
///
/// 返回值约定：`D`（>= 1）；若 1..8192 层全部可解析，返回 0 表示「此范围内无上限」
/// ——调用方必须据此**显式失败**（要么实现真没上限，要么它已不再拒绝超深嵌套）。
fn rc21c_probe_depth_limit() -> Int32 {
  // 前置：0 层（裸字面量）必须可解析，否则这条探针没有意义。
  if !rc21c_parse_ok(0) {
    return 0
  }
  let mut d = 1
  while d <= 8192 {
    if !rc21c_parse_ok(d) {
      return d
    }
    d = d + 1
  }
  0
}

///|
/// 探针的基本前提：`D` 必须探得到，且它两侧的判定要自洽。
///
/// **这条先跑、消息最短**：若探针自身坏了（例如 `parse_ok(0)` 就失败、或整条
/// 全 false），先红的应该是它，而不是让后面几条一起红成一团。
test "rc21c[1]: 探针前提——parse_ok(0) 成立、D 可探到、D 与 D−1 判定自洽" {
  // 前置 1：0 层（裸字面量 "1"）必须可解析。CI 上若这条红，说明解析器连裸字面量
  // 都拒——那是探针的前提崩塌，与「嵌套上限」本身无关，需要先看这一条。
  assert_eq(rc21c_parse_ok(0), true)
  let d = rc21c_probe_depth_limit()
  // 前置 2：必须在 1..8192 内探到上限（返回 0 = 探不到）。
  assert_eq(d > 0, true)
  // 结论：D 解析失败、D−1 解析成功。
  assert_eq(rc21c_parse_ok(d), false)
  assert_eq(rc21c_parse_ok(d - 1), true)
}

///|
/// 越界之后**整段**都失败（不是只失败一格），即「没有部分成功」。
///
/// 与上一条分开：上一条验「边界精确」，这条验「边界之后一路拒」。若探针给出错误
/// 的 D，两条会各自以不同方式红，便于定位。
test "rc21c[2]: 越界后 D+1、D+2 同样失败（不是只失败一格）" {
  let d = rc21c_probe_depth_limit()
  if d > 0 {
    assert_eq(rc21c_parse_ok(d), false)
    assert_eq(rc21c_parse_ok(d + 1), false)
    assert_eq(rc21c_parse_ok(d + 2), false)
  } else {
    // 探不到上限：这条无从判断（由 [1] 负责报错），不在这里伪造结论。
    assert_eq(d, 0)
  }
}

///|
/// 幂次格点（4/8/16/32/64）的判定必须与 `D` 一致。
///
/// 这条**独立于前两条**：即使探针给出错误的 D，它也会自己算一遍
/// 「该格点是否应可解析」再与实测比对，所以红的地方指向具体深度而不是笼统失败。
test "rc21c[3]: 幂次格点的判定与 D 一致（4/8/16/32/64）" {
  let d = rc21c_probe_depth_limit()
  if d > 0 {
    for depth in [4, 8, 16, 32, 64] {
      let expect_ok = depth < d
      // 失败时能直接看到是哪一格：用带深度信息的断言
      assert_eq(rc21c_parse_ok(depth), expect_ok)
    }
  } else {
    assert_eq(d, 0)
  }
}

///|
/// 诊断（永远绿）：把本工具链的关键数值打出来，CI 上直接可读。
///
/// 不参与判定，只提供可观测性——下次若再红，日志里就有 D 的实际值。
test "rc21c[0]: 诊断——打印 D 与 0..8 层判定（不影响判定）" {
  let mut flags = ""
  for depth in 0..<9 {
    let mark = if rc21c_parse_ok(depth) { "T" } else { "F" }
    flags = flags + depth.to_string() + ":" + mark + " "
  }
  println(
    "rc21c 诊断: " + flags + "| D=" + rc21c_probe_depth_limit().to_string(),
  )
  assert_eq(flags.length() > 0, true)
}

// ---------------------------------------------------------------------------
// 「整行」口径：读入口对**一行完整事件**的行为（不是裸嵌套文本）
// ---------------------------------------------------------------------------
//
// 上面几条测的是 `@json.parse("[[[…]]]")` —— 裸嵌套文本。但读入口真正处理的是
// 一行**事件对象**，两者的失败点可能不同：一行对象比裸文本多包了一层 `{}`，
// 有效嵌套预算少 1；更重要的是，**「越界时整行拒绝」这条契约只能在这里验**。
//
// 若实现退化成「解析失败就把未知字段剥掉重试」（= 部分成功），裸文本那几条用例
// 仍然全绿（它压根没走剥字段那条路），只有「整行」口径能抓到。这是本轮（第三次
// CI 修复）实测踩到的盲区：退化实现的 mutation 在旧用例下 740/740 全绿。

///|
/// 一行事件：`{"card_id":…,"x":<depth 层嵌套>}`。
fn rc21c_event_line(depth : Int32) -> String {
  let head = "{" +
    "\"card_id\":\"c\",\"reviewed_at\":1700000000," +
    "\"due_at\":1700000000,\"grade\":3,\"elapsed_days\":1"
  if depth <= 0 {
    head + "}"
  } else {
    head + ",\"x\":" + rc21c_nested_json(depth) + "}"
  }
}

///|
/// 用真实读入口解析「一行事件」：`Some(log)` = 整行被接受，`None` = 整行被拒。
///
/// `from_jsonl` 是 `raise` 型，这里用 `catch` 收敛成 `Option`；除 catch 外**没有**
/// 任何兜底——若实现偷偷「剥字段重试」，越界行会变成 `Some(...)`，用例据此发现。
fn rc21c_parse_event_line(depth : Int32) -> ReviewLog? {
  let text = rc21c_event_line(depth) + "\n"
  let res : Result[ReviewLog, LogError] = ReviewLog::from_jsonl(text) catch {
    _ => return None
  }
  match res {
    Ok(log) => Some(log)
    Err(_) => None
  }
}

///|
/// 用**真实读入口**解析一行（`ReviewLog::from_jsonl`，CLI 用的同一条路）：
/// `true` = 整行被接受且恰好 1 条事件；`false` = 整行被拒（或 0 条）。
///
/// 这一层除 catch 之外没有任何兜底——若实现偷偷「剥字段重试」，越界行会变成
/// `true`，用例据此发现。
fn rc21c_accepts_line(depth : Int32) -> Bool {
  match rc21c_parse_event_line(depth) {
    Some(log) => log.length() == 1
    None => false
  }
}

///|
test "rc21c: 整行口径——越界时整行被拒，且拒绝点是一个精确的边界" {
  let d = rc21c_probe_depth_limit()
  assert_true(d > 0)
  // 从「肯定合法」的深度往上扫，找第一个被读入口拒绝的整行深度 E。
  //
  // 为什么从 1 往上扫而不是从 d 往上扫：整行比裸文本多包一层 `{}`，两者消耗的
  // 嵌套预算不同（实测本机：裸文本 D=1025、整行 E=1025，同值但**不保证**同值，
  // 取决于解析器怎么数顶层）。扫出来的 E 才是「读入口真正的边界」。
  let mut e = 1
  while e <= 4096 && rc21c_accepts_line(e) {
    e = e + 1
  }
  // ① 存在一个「整行被拒」的深度（否则读入口在越界时不肯拒绝——契约不成立）
  assert_true(!rc21c_accepts_line(e))
  // ② 该深度 −1 的整行必须被接受：拒绝点是**精确的一格**，不是「某个拐点之后全拒」
  assert_true(rc21c_accepts_line(e - 1))
  // ③ **没有部分成功**：被拒的深度不能「少一条事件地」通过——
  //    `from_jsonl` 要么给 1 条，要么整体报错；给 `Ok(0 条)` 也算部分成功，要红。
  match rc21c_parse_event_line(e) {
    Some(log) => assert_true(log.length() != 0)
    None => assert_true(true)
  }
}
