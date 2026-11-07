// RJ-2（2026-11-08 审计）：by_card 的排序比较器做 Int64 减法，
// 极值回绕导致排序翻转 —— N-1（days_between 溢出，dcbdd7b）的同型残留。
//
// ## 缺陷形态（修复前）
//
//     let d = a.1.reviewed_at - b.1.reviewed_at
//
// MAX - MIN 回绕成 -1：`[MAX, MIN]` 排序后仍是 MAX 在前。by_card 是
// replay / stats / retention_curve 的分组排序入口，事件顺序颠倒会使
// 重放状态与间隔统计错乱。CLI 的时间戳域（±6.2e10..2.53e11）差值
// 不回绕、不可达；但 ReviewEvent 是 pub(all)，库级可达。
//
// ## 修复
//
// 比较器直接比较（a<b / a>b），不做减法。

///|
test "RJ-2: Int64 极值时间戳排序不回绕" {
  let log = ReviewLog::new()
  let maxev = ReviewEvent::new("c", 9223372036854775807, 0, Grade::Easy, 1.0)
  let minev = ReviewEvent::new(
    "c",
    -9223372036854775807 - 1,
    0,
    Grade::Easy,
    1.0,
  )
  // push 顺序：MAX 先进
  log.events.push(maxev)
  log.events.push(minev)
  let g = log.by_card()
  let arr = match g.get("c") {
    Some(a) => a
    None => fail("missing card")
  }
  // 修复前：MAX - MIN 回绕成 -1，MAX 仍排在 MIN 前
  inspect(arr[0].reviewed_at, content="-9223372036854775808")
  inspect(arr[1].reviewed_at, content="9223372036854775807")
}

///|
test "RJ-2: 反向输入顺序同样正确" {
  let log = ReviewLog::new()
  let maxev = ReviewEvent::new("c", 9223372036854775807, 0, Grade::Easy, 1.0)
  let minev = ReviewEvent::new(
    "c",
    -9223372036854775807 - 1,
    0,
    Grade::Easy,
    1.0,
  )
  log.events.push(minev)
  log.events.push(maxev)
  let g = log.by_card()
  let arr = match g.get("c") {
    Some(a) => a
    None => fail("missing card")
  }
  inspect(arr[0].reviewed_at, content="-9223372036854775808")
  inspect(arr[1].reviewed_at, content="9223372036854775807")
}

///|
test "RJ-2: 常规时间戳的稳定排序不回退" {
  // 相等时间戳保持原顺序（稳定）
  let log = ReviewLog::new()
  log.events.push(ReviewEvent::new("c", 100, 0, Grade::Good, 1.0))
  log.events.push(ReviewEvent::new("c", 100, 0, Grade::Easy, 1.0))
  log.events.push(ReviewEvent::new("c", 50, 0, Grade::Again, 1.0))
  let g = log.by_card()
  let arr = match g.get("c") {
    Some(a) => a
    None => fail("missing card")
  }
  inspect(arr[0].grade is Again, content="true")
  inspect(arr[1].grade is Good, content="true")
  inspect(arr[2].grade is Easy, content="true")
}
