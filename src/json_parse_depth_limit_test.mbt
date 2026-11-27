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
/// 先按 2 的幂倍增 (4, 8, 16, …, 8192) 找上界，再二分到精确值。起点用 **4**
/// 而不是 64：CI 的 D 可能比 64 小，从 4 起步能覆盖那一区间（Lead 2026-11-29
/// 指出的分支从未被执行过）。
///
/// 返回值约定：探到上限时返回 D（≥ 1）；若倍增到 8192 层仍全部可解析，返回 0
/// 表示「本工具链在此范围内无上限」——调用方必须据此**显式失败**，不许静默通过
/// （否则实现退化成「永远部分成功」时会装看不见）。
fn rc21c_probe_depth_limit() -> Int32 {
  let mut lo = 0 // 已知可解析（0 层 = 裸字面量）
  let mut hi = 4
  let mut bounded = false
  while hi <= 8192 {
    if rc21c_parse_ok(hi) {
      lo = hi
      hi = hi + hi
    } else {
      bounded = true
      break
    }
  }
  if !bounded {
    return 0
  }
  // 二分 (lo, hi]：lo 可解析、hi 不可解析
  while lo + 1 < hi {
    let mid = lo + (hi - lo) / 2
    if rc21c_parse_ok(mid) {
      lo = mid
    } else {
      hi = mid
    }
  }
  hi
}

///|
test "rc21c: 自探得到 D，且 D 层解析失败、D−1 层解析成功" {
  let d = rc21c_probe_depth_limit()
  // 「探不到上限」是可疑信号：要么实现真没上限（契约不成立），要么它已不再拒绝
  // 超深嵌套（例如退化成「剥字段重试」）。两种情况都必须红。
  assert_true(d > 0)
  assert_true(!rc21c_parse_ok(d))
  assert_true(rc21c_parse_ok(d - 1))
}

///|
test "rc21c: 越界是**整体**解析失败，不存在「裁掉嵌套继续」的中间态" {
  let d = rc21c_probe_depth_limit()
  assert_true(d > 0)
  // D 层：整段文本解析失败——这是「没有部分成功」的直接证据
  assert_true(!rc21c_parse_ok(d))
  // D+1 层同样失败（不是只失败一格）
  assert_true(!rc21c_parse_ok(d + 1))
  // D−1 层完整解析成功（说明失败点确实只在 D 这一格）
  assert_true(rc21c_parse_ok(d - 1))
}

///|
test "rc21c: 幂次小步长也一致（4/8/16/32/64 层的判定不与 D 冲突）" {
  let d = rc21c_probe_depth_limit()
  assert_true(d > 0)
  for depth in [4, 8, 16, 32, 64] {
    let expect_ok = depth < d
    assert_eq(rc21c_parse_ok(depth), expect_ok)
  }
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
