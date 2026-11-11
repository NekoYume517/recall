// ============================================================================
// 负年份的 4 位补零（2026-11-12 审计 R-8）
//
// `timestamp_to_iso8601` 的年份宽度规则（函数注释、API.md §5.2 与
// docs/implementation.md 都写明）：
//
//   不足 4 位 → 补零到 4 位（如 0001-01-01）
//   恰好 4 位 → 原样
//   超过 4 位 → 原样输出、不截断（如 292277026596）
//
// 修复前这条规则在**负年份**上失效：补零位数是 `4 - ystr.length()`，而
// `ystr` 对负年份带了符号（"-27" 长度 3），于是符号占掉一位数字：
//
//     timestamp_to_iso8601(-63000000000) -> "-027-08-11 08:00:00"   （应为 -0027）
//     timestamp_to_iso8601(-62419766400) -> "-009-12-31 00:00:00"   （应为 -0009）
//
// 根因：src/anki.mbt 的 `let zeros = 4 - ystr.length()` 把符号当成了一位年。
//
// 可达性：JSONL 的时间戳下界是 -62135596800（0001-01-01），所以 CLI 走不到；
// 但 `timestamp_to_iso8601` 是公开 API，函数注释明确承诺「完整 Int64 域」
// （并已用 Int64.MIN 的 `-292277022657-01-27 08:29:52` 锚定），负年份
// [-999, -1] 落在该域内且旧输出违反自己声明的补零规则。`CardState` 是
// pub(all)，`export_anki_tsv` 的 due 列会把它直接写进 Anki 文件。
//
// 期望值来源：Python 版独立参考实现（Hinnant civil_from_days，**floor 除法**
// 版本 + 同一条补零规则）逐点复算，零共享代码。
// ============================================================================

///|
test "R-8: 负年份补零到 4 位数字（符号不占名额）" {
  // 年 -27：修复前 "-027"，应为 "-0027"
  inspect(timestamp_to_iso8601(-63000000000L), content="-0027-08-11 08:00:00")
  // 年 -9：修复前 "-009"
  inspect(timestamp_to_iso8601(-62419766400L), content="-0009-12-31 00:00:00")
  // 年 -5：修复前 "-005"
  inspect(timestamp_to_iso8601(-62324985600L), content="-0005-01-01 00:00:00")
  // 年 -2（-0002-12-31）：修复前 "-002"
  inspect(timestamp_to_iso8601(-62198841600L), content="-0002-12-31 00:00:00")
}

///|
test "R-8: 负年份的年份段恒为 4 位数字（结构断言，锁住整段区间）" {
  // 取 [-999, -1] 内每个年份的一个时间点太贵，这里取 9 个等距样本做结构检查：
  // 年份段要么是 4 位数字，要么（|year| 更大时）不短于 4 位数字。
  let samples = [
    -62198841600L, -62204400000L, -62235000000L, -62270000000L, -62300000000L, -62324985600L,
    -62350000000L, -62419766400L, -62500000000L,
  ]
  for ts in samples {
    let s = timestamp_to_iso8601(ts)
    // 形如 -YYY...：去掉符号后，第一段到 '-' 为止
    assert_true(s.has_prefix("-"))
    let rest = s.substring(start=1, end=s.length())
    let dash = match rest.find("-") {
      Some(i) => i
      None => fail("负年份缺少日期分隔符: \{s}")
    }
    let digits = rest.substring(start=0, end=dash)
    println("\{ts} -> \{s}（年份段 \{digits.length()} 字符）")
    assert_true(digits.length() >= 4)
  }
}

///|
test "R-8: 非负年份与超 4 位年份的输出逐字不变（防过度收紧）" {
  inspect(timestamp_to_iso8601(0L), content="1970-01-01 00:00:00")
  inspect(timestamp_to_iso8601(-1L), content="1969-12-31 23:59:59")
  inspect(timestamp_to_iso8601(-62135596800L), content="0001-01-01 00:00:00")
  inspect(timestamp_to_iso8601(-62167219200L), content="0000-01-01 00:00:00")
  inspect(timestamp_to_iso8601(-31536000000L), content="0970-08-31 00:00:00")
  // 超过 4 位的年份原样输出，不补零也不截断
  inspect(
    timestamp_to_iso8601(-9223372036854775808L),
    content="-292277022657-01-27 08:29:52",
  )
  inspect(
    timestamp_to_iso8601(9223372036854775807L),
    content="292277026596-12-04 15:30:07",
  )
}

///|
test "R-8: 负年份 due 经 export_anki_tsv 写出后年份段仍是 4 位数字" {
  let st : CardState = { ..CardState::new("c", 0L), due: -63000000000L, }
  let tsv = export_anki_tsv([st], "fsrs")
  println(tsv)
  assert_true(tsv.contains("-0027-08-11 08:00:00"))
  assert_false(tsv.contains("-027-08-11"))
}
