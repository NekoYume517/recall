// ============================================================================
// anki_test.mbt — Anki 可读格式导出的回归测试
//
// 契约：
//   1. ISO8601 历法换算对已知日期精确（含闰日、世纪边界）
//   2. 指令头（separator/html/columns）与调度器来源注释齐全
//   3. 卡片按 card_id 排序，两次导出逐字节相同
//   4. 与 replay 引擎共享状态逻辑（导出不引入第二份状态机）
//   5. difficulty 列的语义随调度器分派（普通注释标注来源）
// ============================================================================

///|
/// 测试辅助：解析日志，坏行直接 abort（测试上下文里不会发生）。
fn anki_parse_log(text : String) -> ReviewLog {
  // from_jsonl 的签名是 Result[..] raise：catch 得到 Result，再解包。
  // 测试日志不会坏，坏了 abort 让测试立刻失败。
  let parsed = ReviewLog::from_jsonl(text) catch { _ => abort("bad test log") }
  match parsed {
    Ok(log) => log
    Err(_) => abort("bad test log")
  }
}

///|
test "anki: ISO8601 已知日期精确（含闰日与 9999 边界）" {
  // 期望值经 Python datetime 独立复算（UTC）。
  // 注意 951782400 是 2000-02-29：2000 是闰年——曾把期望值错写成 02-28，
  // Python 复算纠正，顺带证明实现把闰日处理对了。
  let cases : Array[(Timestamp, String)] = [
    (0L, "1970-01-01 00:00:00"),
    (86400L, "1970-01-02 00:00:00"),
    (1700000000L, "2023-11-14 22:13:20"),
    (951782400L, "2000-02-29 00:00:00"),
    (951868800L, "2000-03-01 00:00:00"),
    (1709164800L, "2024-02-29 00:00:00"),
    (-2203977600L, "1900-02-28 00:00:00"), // UTC 值经 Python 复算,
    (253402300799L, "9999-12-31 23:59:59"),
  ]
  for c in cases {
    let (ts, want) = c
    assert_eq(timestamp_to_iso8601(ts), want)
  }
}

// ─────────────────────────────────────────────────────────────────
// RC-6（2026-10-27）：修正年份宽度的契约描述，并锁定真实行为
//
// 原注释写「年份补 4 位（**Anki 的 CSV 解析器期待 4 位年**）」，
// 但实现只在 ystr.length() < 4 时补零，超过 4 位原样输出——从没有过
// "4 位" 这个约束。于是注释承诺了一条实现从未执行的规则。
//
// 触发条件是本库自己产生的合法值：JSONL 允许的 reviewed_at 上限是
// 253402300799（= 9999-12-31 23:59:59），加上 max_interval_days() = 36500
// 天即得到 10099 年；Int64 上限对应 1587287 年。
//
// 裁决（2026-10-27）：**保持不截断**——年份不足 4 位补零，超过 4 位原样
// 输出。截断会把 10099 年变成 0099 年（把未来的到期日说成公元 99 年），
// 比"多一位数字"更糟。因此这里做的是：把注释改成如实描述，并用测试
// 锁定当前行为，防止将来有人照着旧注释去"修"成 4 位。
// ─────────────────────────────────────────────────────────────────

///|
test "RC-6: 年份不足 4 位补零，超过 4 位原样输出（不截断）" {
  // 不足 4 位：补零到 4 位（既有行为，防回归）
  assert_eq(timestamp_to_iso8601(-59011459200L), "0100-01-01 00:00:00")
  assert_eq(timestamp_to_iso8601(-62135596800L), "0001-01-01 00:00:00")
  // 恰好 4 位：不补
  assert_eq(timestamp_to_iso8601(253402300799L), "9999-12-31 23:59:59")
  // 超过 4 位：原样输出，不截断也不补
  assert_eq(
    timestamp_to_iso8601(9223372036854775807L),
    "1587287-03-17 15:30:07",
  )
}

///|
test "RC-6: JSONL 上限时间戳 + 36500 天给出 10099 年（不截断）" {
  // 这是从日志可达的最远 due（reviewed_at 取 JSONL 上限、间隔取上限）
  let ts = add_days(253402300799L, 36500.0)
  let s = timestamp_to_iso8601(ts)
  println("add_days(253402300799, 36500) -> " + s)
  assert_eq(s, "10099-12-06 23:59:59")
  // 关键：年份段完整，不可能是被截断的 "0099"
  let year = s.split("-").collect()[0]
  assert_eq(year, "10099")
}

///|
test "RC-6: 端到端——合法日志的 --anki 导出里 due 年份完整" {
  // 用 12 次连续 Easy + 靠近上限的 reviewed_at 造出 due > 9999 年，
  // 这是完全合法的 JSONL（reviewed_at 都在允许域内）。
  let log = ReviewLog::new()
  let mut t : Timestamp = 253000000000L
  for _ in 0..<12 {
    log.push(ReviewEvent::new("c1", t, t, Grade::Easy, 0.0))
    t = t + 86400L * 400L
  }
  let out = export_anki_from_log(log, AnyScheduler::Fsrs(Fsrs::new()))
  println(out)
  let data = out.split("\n").collect()[4].split("\t").collect()
  let due = data[5]
  assert_eq(due, "10063-05-09 17:46:40")
  // 8 列结构不被破坏
  assert_eq(data.length(), 8)
  assert_eq(data[7], "复习")
}

///|
test "RC-6: 修复不改变 4 位及以内年份的既有输出" {
  // 防回归：所有已知锚点逐字节不变
  assert_eq(timestamp_to_iso8601(0L), "1970-01-01 00:00:00")
  assert_eq(timestamp_to_iso8601(-1L), "1969-12-31 23:59:59")
  assert_eq(timestamp_to_iso8601(-86400L), "1969-12-31 00:00:00")
  assert_eq(timestamp_to_iso8601(1700000000L), "2023-11-14 22:13:20")
  assert_eq(timestamp_to_iso8601(951782400L), "2000-02-29 00:00:00")
  assert_eq(timestamp_to_iso8601(-2203977600L), "1900-02-28 00:00:00")
}

///|
test "anki: 导出格式头齐全且行序稳定" {
  let log = anki_parse_log(
    "{\"card_id\":\"b\",\"reviewed_at\":1700000000,\"due_at\":1699999000,\"grade\":3,\"elapsed_days\":0}\n" +
    "{\"card_id\":\"a\",\"reviewed_at\":1700000000,\"due_at\":1699999000,\"grade\":3,\"elapsed_days\":0}\n",
  )
  let out = export_anki_from_log(log, AnyScheduler::Fsrs(Fsrs::new()))
  let lines = out.split("\n").collect()
  // 指令头在前四行
  assert_eq(lines[0], "#separator:tab")
  assert_eq(lines[1], "#html:false")
  assert_true(lines[2].has_prefix("# scheduler: fsrs"))
  assert_true(lines[3].has_prefix("#columns:card_id\t"))
  // 数据行按 card_id 排序：a 在 b 前
  let first_data = lines[4].split("\t").collect()
  let second_data = lines[5].split("\t").collect()
  assert_eq(first_data[0], "a")
  assert_eq(second_data[0], "b")
  // 共 4 头 + 2 数据 + 尾空 = 7 元素
  assert_eq(lines.length(), 7)
}

///|
test "anki: 同日志两次导出逐字节相同（确定性）" {
  let log = anki_parse_log(
    "{\"card_id\":\"c1\",\"reviewed_at\":1700000000,\"due_at\":1699999000,\"grade\":3,\"elapsed_days\":0}\n" +
    "{\"card_id\":\"c2\",\"reviewed_at\":1700000100,\"due_at\":1700000000,\"grade\":0,\"elapsed_days\":1}\n",
  )
  let s : AnyScheduler = AnyScheduler::Fsrs(Fsrs::new())
  let a = export_anki_from_log(log, s)
  let b = export_anki_from_log(log, s)
  assert_eq(a, b)
}

///|
test "anki: 数据行字段与 CardState 一致" {
  let log = anki_parse_log(
    "{\"card_id\":\"x\",\"reviewed_at\":1700000000,\"due_at\":1699999000,\"grade\":3,\"elapsed_days\":0}\n",
  )
  let out = export_anki_from_log(log, AnyScheduler::Fsrs(Fsrs::new()))
  // 找到数据行
  let mut data_line = ""
  for line in out.split("\n") {
    if line.has_prefix("x\t") {
      data_line = line.to_owned()
      break
    }
  }
  assert_true(data_line.length() > 0)
  let fields = data_line.split("\t").collect()
  assert_eq(fields.length(), 8)
  assert_eq(fields[0], "x")
  // stability / difficulty / reps / lapses 都非空
  // （值本身由 FSRS 公式决定，不在这里重复断言——手算表在 fsrs_test）
  for i = 1; i < 5; i = i + 1 {
    assert_true(fields[i].length() > 0)
  }
  // due 列是 ISO8601：YYYY-MM-DD HH:MM:SS（第 5、11 字符是 '-' 与空格）
  assert_eq(fields[5].length(), 19)
  let due = fields[5].to_owned()
  assert_eq(due[4].to_int(), '-'.to_int())
  assert_eq(due[10].to_int(), ' '.to_int())
  // 阶段列：首评 Good 后进入 Review 或 Learning（间隔决定）
  assert_true(fields[7] == "复习" || fields[7] == "学习中")
}

///|
test "anki: 来源注释随调度器变化（difficulty 语义防误读）" {
  let log = anki_parse_log(
    "{\"card_id\":\"k\",\"reviewed_at\":1700000000,\"due_at\":1699999000,\"grade\":3,\"elapsed_days\":0}\n",
  )
  let a = export_anki_from_log(log, AnyScheduler::Fsrs(Fsrs::new()))
  let b = export_anki_from_log(log, AnyScheduler::Sm2(Sm2::new()))
  assert_true(a.contains("# scheduler: fsrs"))
  assert_true(b.contains("# scheduler: sm2"))
}

///|
test "anki: 空日志导出只有指令头" {
  let log = anki_parse_log("")
  let out = export_anki_from_log(log, AnyScheduler::Fsrs(Fsrs::new()))
  let lines = out.split("\n").collect()
  assert_eq(lines[0], "#separator:tab")
  // 4 行头 + 尾空 = 5 元素
  assert_eq(lines.length(), 5)
}
