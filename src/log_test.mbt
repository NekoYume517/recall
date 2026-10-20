// log.mbt 白盒测试
//
// 覆盖：事件构造、JSONL 往返、分组排序、各种坏行错误、以及
// **30 条真实事件的读入**。
//
// ⚠️ 测试自包含：30 行数据以字符串常量内联在 `example_jsonl()` 里，
// 不读文件。原因：`moon test` 的工作目录不保证是仓库根，相对路径
// 换台机器就会挂。内容与 examples/reviews.jsonl 完全一致（6 张卡 × 5 次）。
//
// 共享辅助函数 `approx` 在 test_helpers_test.mbt。

///|
/// 造一条事件，省掉重复的 due_at 样板。
fn ev(
  card_id : String,
  reviewed_at : Timestamp,
  grade : Grade,
  elapsed : Double,
) -> ReviewEvent {
  ReviewEvent::new(card_id, reviewed_at, reviewed_at - 60L, grade, elapsed)
}

///|
/// examples/reviews.jsonl 的 30 行内容（内联，保证任何目录都能跑）。
///
/// 每张卡 5 次复习，elapsed 序列 0 / 1 / 3 / 8 / 21，评分 3,4,4,3,4。
fn example_jsonl() -> String {
  "{\"card_id\":\"c1\",\"reviewed_at\":1700000000,\"due_at\":1699999940,\"grade\":3,\"elapsed_days\":0}\n" +
  "{\"card_id\":\"c1\",\"reviewed_at\":1700086400,\"due_at\":1700086340,\"grade\":4,\"elapsed_days\":1}\n" +
  "{\"card_id\":\"c1\",\"reviewed_at\":1700345600,\"due_at\":1700345540,\"grade\":4,\"elapsed_days\":3}\n" +
  "{\"card_id\":\"c1\",\"reviewed_at\":1701036800,\"due_at\":1701036740,\"grade\":3,\"elapsed_days\":8}\n" +
  "{\"card_id\":\"c1\",\"reviewed_at\":1702851200,\"due_at\":1702851140,\"grade\":4,\"elapsed_days\":21}\n" +
  "{\"card_id\":\"c2\",\"reviewed_at\":1706048000,\"due_at\":1706047940,\"grade\":3,\"elapsed_days\":0}\n" +
  "{\"card_id\":\"c2\",\"reviewed_at\":1706134400,\"due_at\":1706134340,\"grade\":4,\"elapsed_days\":1}\n" +
  "{\"card_id\":\"c2\",\"reviewed_at\":1706393600,\"due_at\":1706393540,\"grade\":4,\"elapsed_days\":3}\n" +
  "{\"card_id\":\"c2\",\"reviewed_at\":1707084800,\"due_at\":1707084740,\"grade\":3,\"elapsed_days\":8}\n" +
  "{\"card_id\":\"c2\",\"reviewed_at\":1708899200,\"due_at\":1708899140,\"grade\":4,\"elapsed_days\":21}\n" +
  "{\"card_id\":\"c3\",\"reviewed_at\":1712096000,\"due_at\":1712095940,\"grade\":3,\"elapsed_days\":0}\n" +
  "{\"card_id\":\"c3\",\"reviewed_at\":1712182400,\"due_at\":1712182340,\"grade\":4,\"elapsed_days\":1}\n" +
  "{\"card_id\":\"c3\",\"reviewed_at\":1712441600,\"due_at\":1712441540,\"grade\":4,\"elapsed_days\":3}\n" +
  "{\"card_id\":\"c3\",\"reviewed_at\":1713132800,\"due_at\":1713132740,\"grade\":3,\"elapsed_days\":8}\n" +
  "{\"card_id\":\"c3\",\"reviewed_at\":1714947200,\"due_at\":1714947140,\"grade\":4,\"elapsed_days\":21}\n" +
  "{\"card_id\":\"d1\",\"reviewed_at\":1718144000,\"due_at\":1718143940,\"grade\":3,\"elapsed_days\":0}\n" +
  "{\"card_id\":\"d1\",\"reviewed_at\":1718230400,\"due_at\":1718230340,\"grade\":4,\"elapsed_days\":1}\n" +
  "{\"card_id\":\"d1\",\"reviewed_at\":1718489600,\"due_at\":1718489540,\"grade\":4,\"elapsed_days\":3}\n" +
  "{\"card_id\":\"d1\",\"reviewed_at\":1719180800,\"due_at\":1719180740,\"grade\":3,\"elapsed_days\":8}\n" +
  "{\"card_id\":\"d1\",\"reviewed_at\":1720995200,\"due_at\":1720995140,\"grade\":4,\"elapsed_days\":21}\n" +
  "{\"card_id\":\"d2\",\"reviewed_at\":1724192000,\"due_at\":1724191940,\"grade\":3,\"elapsed_days\":0}\n" +
  "{\"card_id\":\"d2\",\"reviewed_at\":1724278400,\"due_at\":1724278340,\"grade\":4,\"elapsed_days\":1}\n" +
  "{\"card_id\":\"d2\",\"reviewed_at\":1724537600,\"due_at\":1724537540,\"grade\":4,\"elapsed_days\":3}\n" +
  "{\"card_id\":\"d2\",\"reviewed_at\":1725228800,\"due_at\":1725228740,\"grade\":3,\"elapsed_days\":8}\n" +
  "{\"card_id\":\"d2\",\"reviewed_at\":1727043200,\"due_at\":1727043140,\"grade\":4,\"elapsed_days\":21}\n" +
  "{\"card_id\":\"e1\",\"reviewed_at\":1730240000,\"due_at\":1730239940,\"grade\":3,\"elapsed_days\":0}\n" +
  "{\"card_id\":\"e1\",\"reviewed_at\":1730326400,\"due_at\":1730326340,\"grade\":4,\"elapsed_days\":1}\n" +
  "{\"card_id\":\"e1\",\"reviewed_at\":1730585600,\"due_at\":1730585540,\"grade\":4,\"elapsed_days\":3}\n" +
  "{\"card_id\":\"e1\",\"reviewed_at\":1731276800,\"due_at\":1731276740,\"grade\":3,\"elapsed_days\":8}\n" +
  "{\"card_id\":\"e1\",\"reviewed_at\":1733091200,\"due_at\":1733091140,\"grade\":4,\"elapsed_days\":21}\n"
}

///|
/// 把 fixture 解析成日志。
///
/// 注意：`from_jsonl` 的签名是 `Result[...] raise`，所以调用点必须包在
/// `try` 里（函数既有错误返回又能 raise）。本助手不是 raise 函数，
/// 因此这里吞掉异常；解析失败会返回空日志，后续断言的长度检查
/// 会立刻失败并暴露问题。
fn parse_example() -> ReviewLog {
  let text = example_jsonl()
  let parsed = ReviewLog::from_jsonl(text) catch {
    _ => return ReviewLog::new()
  }
  match parsed {
    Ok(log) => log
    Err(_) => ReviewLog::new()
  }
}

// ─────────────────────────────────────────────────────────────────
// 构造与基本操作
// ─────────────────────────────────────────────────────────────────

///|
test "new 是空日志" {
  let log = ReviewLog::new()
  inspect(log.length(), content="0")
  inspect(log.is_empty(), content="true")
}

///|
test "push 保持插入顺序" {
  let log = ReviewLog::new()
  log.push(ev("a", 100L, Grade::Good, 0.0))
  log.push(ev("b", 200L, Grade::Easy, 1.0))
  log.push(ev("a", 300L, Grade::Again, 2.0))
  inspect(log.length(), content="3")
  inspect(log.events[0].card_id, content="a")
  inspect(log.events[1].card_id, content="b")
  inspect(log.events[2].reviewed_at.to_string(), content="300")
}

///|
test "ReviewEvent::new 把负 elapsed 夹到 0" {
  let e = ReviewEvent::new("c1", 100L, 90L, Grade::Good, -5.0)
  let d = e.elapsed_days
  assert_true(approx(d, 0.0, 0.000000001))
}

///|
test "overdue_days 提前复习返回 0" {
  let e = ReviewEvent::new("c1", 900L, 1000L, Grade::Good, 1.0)
  let d = e.overdue_days()
  assert_true(approx(d, 0.0, 0.000000001))
}

///|
test "overdue_days 逾期计算" {
  let e = ReviewEvent::new("c1", 172800L, 0L, Grade::Good, 2.0)
  let d = e.overdue_days()
  assert_true(approx(d, 2.0, 0.000000001))
}

///|
test "event equal 逐字段" {
  let a = ev("c1", 100L, Grade::Good, 1.0)
  let b = ev("c1", 100L, Grade::Good, 1.0)
  inspect(ReviewEvent::equal(a, b), content="true")
  let c = ev("c1", 100L, Grade::Easy, 1.0)
  inspect(ReviewEvent::equal(a, c), content="false")
}

// ─────────────────────────────────────────────────────────────────
// JSONL 单行格式
// ─────────────────────────────────────────────────────────────────

///|
test "to_jsonl 单行字段名与顺序固定" {
  let log = ReviewLog::new()
  log.push(ReviewEvent::new("c1", 1700000000L, 1699999000L, Grade::Good, 1.0))
  inspect(
    log.to_jsonl(),
    content="{\"card_id\":\"c1\",\"reviewed_at\":1700000000,\"due_at\":1699999000,\"grade\":3,\"elapsed_days\":1}\n",
  )
}

///|
test "to_jsonl integer elapsed 输出为 1 而不是 1.0" {
  let log = ReviewLog::new()
  log.push(ReviewEvent::new("c1", 100L, 0L, Grade::Good, 21.0))
  let out = log.to_jsonl()
  inspect(out.contains("\"elapsed_days\":21"), content="true")
  inspect(out.contains("21.0"), content="false")
}

///|
test "to_jsonl 小数 elapsed 保留小数" {
  let log = ReviewLog::new()
  log.push(ReviewEvent::new("c1", 100L, 0L, Grade::Good, 1.5))
  inspect(log.to_jsonl().contains("\"elapsed_days\":1.5"), content="true")
}

///|
test "空日志 to_jsonl 是空串" {
  inspect(ReviewLog::new().to_jsonl(), content="")
}

///|
test "card_id 含特殊字符时转义正确（不手拼 JSON 的理由）" {
  let log = ReviewLog::new()
  let weird = "a\"b\\c\td"
  log.push(ReviewEvent::new(weird, 100L, 0L, Grade::Good, 1.0))
  let text = log.to_jsonl()
  match ReviewLog::from_jsonl(text) {
    Ok(back) => {
      inspect(back.length(), content="1")
      inspect(back.events[0].card_id, content=weird)
    }
    Err(_) => inspect("parse failed", content="parsed")
  }
}

// ─────────────────────────────────────────────────────────────────
// JSONL 往返
// ─────────────────────────────────────────────────────────────────

///|
test "JSONL 往返一致（多种评分与小数）" {
  let log = ReviewLog::new()
  log.push(ev("c1", 1700000000L, Grade::Again, 0.0))
  log.push(ev("c1", 1700086400L, Grade::Hard, 1.0))
  log.push(ev("c2", 1700172800L, Grade::Good, 3.5))
  log.push(ev("c2", 1700259200L, Grade::Easy, 0.25))
  let text = log.to_jsonl()
  match ReviewLog::from_jsonl(text) {
    Ok(back) => {
      inspect(back.length(), content="4")
      inspect(ReviewLog::equal(log, back), content="true")
    }
    Err(_) => inspect("parse failed", content="parsed")
  }
}

///|
test "往返后能再次序列化成相同字节（幂等）" {
  let log = ReviewLog::new()
  log.push(ev("c1", 1700000000L, Grade::Good, 1.0))
  log.push(ev("c2", 1700086400L, Grade::Easy, 2.0))
  let first = log.to_jsonl()
  match ReviewLog::from_jsonl(first) {
    Ok(back) => inspect(back.to_jsonl(), content=first)
    Err(_) => inspect("parse failed", content="parsed")
  }
}

///|
test "from_jsonl 跳过空行但行号仍然准确" {
  let text = "\n{\"card_id\":\"c1\",\"reviewed_at\":100,\"due_at\":0,\"grade\":3,\"elapsed_days\":1}\n\n{\"card_id\":\"c2\",\"reviewed_at\":200,\"due_at\":0,\"grade\":3,\"elapsed_days\":1}\n"
  match ReviewLog::from_jsonl(text) {
    Ok(log) => {
      inspect(log.length(), content="2")
      inspect(log.events[0].card_id, content="c1")
      inspect(log.events[1].card_id, content="c2")
    }
    Err(_) => inspect("parse failed", content="parsed")
  }
}

///|
test "from_jsonl 容忍行尾空白与 CRLF" {
  let text = "{\"card_id\":\"c1\",\"reviewed_at\":100,\"due_at\":0,\"grade\":3,\"elapsed_days\":1}  \r\n"
  match ReviewLog::from_jsonl(text) {
    Ok(log) => inspect(log.length(), content="1")
    Err(_) => inspect("parse failed", content="parsed")
  }
}

///|
test "空文本读出空日志" {
  match ReviewLog::from_jsonl("") {
    Ok(log) => inspect(log.length(), content="0")
    Err(_) => inspect("parse failed", content="parsed")
  }
}

// ─────────────────────────────────────────────────────────────────
// 错误处理（行号必须准确）
// ─────────────────────────────────────────────────────────────────

///|
test "坏 JSON 报第 2 行" {
  let text = "{\"card_id\":\"c1\",\"reviewed_at\":100,\"due_at\":0,\"grade\":3,\"elapsed_days\":1}\n{bad}\n"
  match ReviewLog::from_jsonl(text) {
    Ok(_) => inspect("should fail", content="failed")
    Err(BadLine(line, _)) => inspect(line, content="2")
    Err(_) => inspect("wrong error", content="BadLine")
  }
}

///|
test "缺字段报 BadLine 且带行号" {
  let text = "{\"card_id\":\"c1\",\"reviewed_at\":100,\"due_at\":0}\n"
  match ReviewLog::from_jsonl(text) {
    Ok(_) => inspect("should fail", content="failed")
    Err(BadLine(line, _)) => inspect(line, content="1")
    Err(_) => inspect("wrong error", content="BadLine")
  }
}

///|
test "时间戳类型错误报 BadTimestamp" {
  let text = "{\"card_id\":\"c1\",\"reviewed_at\":\"not-a-number\",\"due_at\":0,\"grade\":3,\"elapsed_days\":1}\n"
  match ReviewLog::from_jsonl(text) {
    Ok(_) => inspect("should fail", content="failed")
    Err(BadTimestamp(line, _)) => inspect(line, content="1")
    Err(_) => inspect("wrong error", content="BadTimestamp")
  }
}

///|
test "顶层不是对象报 BadLine" {
  match ReviewLog::from_jsonl("[1,2,3]\n") {
    Ok(_) => inspect("should fail", content="failed")
    Err(BadLine(line, _)) => inspect(line, content="1")
    Err(_) => inspect("wrong error", content="BadLine")
  }
}

///|
test "坏行不做部分成功（前面合法行也一起丢弃）" {
  let text = "{\"card_id\":\"c1\",\"reviewed_at\":100,\"due_at\":0,\"grade\":3,\"elapsed_days\":1}\nXXX\n"
  match ReviewLog::from_jsonl(text) {
    Ok(_) => inspect("SHOULD-NOT-PARSE", content="rejected")
    Err(_) => inspect("rejected", content="rejected")
  }
}

// ─────────────────────────────────────────────────────────────────
// 分组与排序
// ─────────────────────────────────────────────────────────────────

///|
test "by_card 分组正确" {
  let log = ReviewLog::new()
  log.push(ev("a", 100L, Grade::Good, 0.0))
  log.push(ev("b", 200L, Grade::Good, 0.0))
  log.push(ev("a", 300L, Grade::Good, 1.0))
  log.push(ev("c", 400L, Grade::Good, 0.0))
  log.push(ev("a", 500L, Grade::Good, 1.0))
  let groups = log.by_card()
  inspect(groups.length(), content="3")
  match groups.get("a") {
    Some(arr) => inspect(arr.length(), content="3")
    None => inspect("missing a", content="found")
  }
  match groups.get("b") {
    Some(arr) => inspect(arr.length(), content="1")
    None => inspect("missing b", content="found")
  }
}

///|
test "by_card 每组按 reviewed_at 升序" {
  let log = ReviewLog::new()
  log.push(ev("a", 300L, Grade::Good, 2.0))
  log.push(ev("a", 100L, Grade::Good, 0.0))
  log.push(ev("a", 200L, Grade::Good, 1.0))
  match log.by_card().get("a") {
    Some(arr) => {
      inspect(arr[0].reviewed_at.to_string(), content="100")
      inspect(arr[1].reviewed_at.to_string(), content="200")
      inspect(arr[2].reviewed_at.to_string(), content="300")
    }
    None => inspect("missing a", content="found")
  }
}

///|
test "by_card 同一秒的事件保持文件原顺序（稳定排序）" {
  let log = ReviewLog::new()
  log.push(ev("a", 100L, Grade::Again, 5.0))
  log.push(ev("a", 100L, Grade::Hard, 6.0))
  log.push(ev("a", 100L, Grade::Good, 7.0))
  match log.by_card().get("a") {
    Some(arr) => {
      assert_true(approx(arr[0].elapsed_days, 5.0, 0.000000001))
      assert_true(approx(arr[1].elapsed_days, 6.0, 0.000000001))
      assert_true(approx(arr[2].elapsed_days, 7.0, 0.000000001))
    }
    None => inspect("missing a", content="found")
  }
}

///|
test "by_card 不改变原日志顺序" {
  let log = ReviewLog::new()
  log.push(ev("b", 300L, Grade::Good, 0.0))
  log.push(ev("a", 100L, Grade::Good, 0.0))
  let _ = log.by_card()
  inspect(log.events[0].card_id, content="b")
  inspect(log.events[1].card_id, content="a")
}

///|
test "card_ids 去重且保持首次出现顺序" {
  let log = ReviewLog::new()
  log.push(ev("b", 100L, Grade::Good, 0.0))
  log.push(ev("a", 200L, Grade::Good, 0.0))
  log.push(ev("b", 300L, Grade::Good, 0.0))
  let ids = log.card_ids()
  inspect(ids.length(), content="2")
  inspect(ids[0], content="b")
  inspect(ids[1], content="a")
}

// ─────────────────────────────────────────────────────────────────
// 30 条真实事件（内联 fixture，与 examples/reviews.jsonl 一致）
// ─────────────────────────────────────────────────────────────────

///|
test "30 条事件能读入，6 张卡各 5 次" {
  let log = parse_example()
  inspect(log.length(), content="30")
  let groups = log.by_card()
  inspect(groups.length(), content="6")
  for id in ["c1", "c2", "c3", "d1", "d2", "e1"] {
    match groups.get(id) {
      Some(arr) => inspect(arr.length(), content="5")
      None => inspect("missing " + id, content="found")
    }
  }
}

///|
test "首条事件内容正确" {
  let log = parse_example()
  let first = log.events[0]
  inspect(first.card_id, content="c1")
  inspect(first.reviewed_at.to_string(), content="1700000000")
  inspect(first.due_at.to_string(), content="1699999940")
  inspect(Grade::label(first.grade), content="good")
  let e0 = first.elapsed_days
  assert_true(approx(e0, 0.0, 0.000000001))
}

///|
test "每张卡的间隔序列是 0,1,3,8,21" {
  let groups = parse_example().by_card()
  match groups.get("c1") {
    Some(arr) => {
      assert_true(approx(arr[0].elapsed_days, 0.0, 0.000000001))
      assert_true(approx(arr[1].elapsed_days, 1.0, 0.000000001))
      assert_true(approx(arr[2].elapsed_days, 3.0, 0.000000001))
      assert_true(approx(arr[3].elapsed_days, 8.0, 0.000000001))
      assert_true(approx(arr[4].elapsed_days, 21.0, 0.000000001))
    }
    None => inspect("missing c1", content="found")
  }
}

///|
test "每张卡的评分序列是 Good,Easy,Easy,Good,Easy" {
  let groups = parse_example().by_card()
  match groups.get("e1") {
    Some(arr) => {
      inspect(Grade::to_int(arr[0].grade), content="3")
      inspect(Grade::to_int(arr[1].grade), content="5")
      inspect(Grade::to_int(arr[2].grade), content="5")
      inspect(Grade::to_int(arr[3].grade), content="3")
      inspect(Grade::to_int(arr[4].grade), content="5")
    }
    None => inspect("missing e1", content="found")
  }
}

///|
test "30 条事件往返后语义完全一致" {
  let log = parse_example()
  match ReviewLog::from_jsonl(log.to_jsonl()) {
    Ok(back) => {
      inspect(back.length(), content="30")
      inspect(ReviewLog::equal(log, back), content="true")
    }
    Err(_) => inspect("failed", content="parsed")
  }
}

///|
test "30 条事件往返字节稳定" {
  let log = parse_example()
  let out = log.to_jsonl()
  match ReviewLog::from_jsonl(out) {
    Ok(again) => inspect(again.to_jsonl(), content=out)
    Err(_) => inspect("failed", content="parsed")
  }
}

///|
test "grade 4/5 归一化为 Easy=5（契约固有的有损点）" {
  // API.md 的 Grade 只有 4 档，但 JSON 里 grade 是 0..5 的整数：
  //   from_int: 0→Again, 1|2→Hard, 3→Good, 4|5→Easy
  //   to_int:   Again→0, Hard→2, Good→3, Easy→5
  // 因此 4 和 5 都是 Easy，写回时统一成 5。这不是 bug，是契约的归一化。
  let g4 = Grade::from_int(4)
  let g5 = Grade::from_int(5)
  inspect(Grade::to_int(g4), content="5")
  inspect(Grade::to_int(g5), content="5")
  inspect(g4 == g5, content="true")
}

///|
test "往返只做一次归一化，之后字节稳定（幂等）" {
  let log = parse_example()
  let once = log.to_jsonl()
  match ReviewLog::from_jsonl(once) {
    Ok(back) => {
      // 第二次序列化必须与第一次完全一致
      let twice = back.to_jsonl()
      inspect(twice, content=once)
      // 第三次也一样
      match ReviewLog::from_jsonl(twice) {
        Ok(again) => inspect(again.to_jsonl(), content=once)
        Err(_) => inspect("failed", content="parsed")
      }
    }
    Err(_) => inspect("failed", content="parsed")
  }
}

///|
test "归一化只影响 grade 字段，其余字段逐字节不变" {
  // fixture 里 grade 只有 3 和 4 两种；3→Good→3 不变，4→Easy→5 变化。
  // 其余（card_id / 时间戳 / elapsed）必须原样保留。
  let original = example_jsonl()
  let normalized = parse_example().to_jsonl()
  // 把原始 fixture 里的 "grade":4 换成 "grade":5 后，应当与输出完全一致
  let expected = original.replace_all(old="\"grade\":4", new="\"grade\":5")
  inspect(normalized, content=expected)
}

///|
// 回归：elapsed_days 的非有限值（Infinity / NaN）必须被拒绝，不能静默进入统计。
// 旧实现 field_double 直接返回 JSON Number，下游归桶时 Infinity 会溢出、上界打印成
// 异常大值。grade 的非整数（如 4）是特性不是 bug，无需校验；只校验 elapsed 有限性。
test "JSONL: elapsed_days 为 Infinity/NaN 被拒绝" {
  let inf = "{\"card_id\":\"a\",\"reviewed_at\":1700000000,\"due_at\":1699999940,\"grade\":3,\"elapsed_days\":1e400}\n"
  let nan = "{\"card_id\":\"a\",\"reviewed_at\":1700000000,\"due_at\":1699999940,\"grade\":3,\"elapsed_days\":NaN}\n"
  let bad_inf = ReviewLog::from_jsonl(inf)
  let bad_nan = ReviewLog::from_jsonl(nan)
  assert_true(bad_inf is Err(_))
  assert_true(bad_nan is Err(_))
}

///|
// 回归：elapsed_days 负数被夹成 0（与 ReviewEvent::new 一致），不拒绝。
test "JSONL: elapsed_days 负数夹成 0" {
  let neg = "{\"card_id\":\"a\",\"reviewed_at\":1700000000,\"due_at\":1699999940,\"grade\":3,\"elapsed_days\":-2}\n"
  match ReviewLog::from_jsonl(neg) {
    Ok(log) => assert_true(log.events[0].elapsed_days == 0.0)
    Err(_) => assert_true(false)
  }
}
