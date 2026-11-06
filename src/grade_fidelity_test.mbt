// 组委会验收意见（2026-11-07）的回归：评分值在读写往返后必须逐字保留
// （RJ-R）。
//
// ## 缺陷形态（修复前）
//
// `Grade` 是 4 档枚举，JSONL 的 `grade` 是 0..5 的 6 值刻度：
// `1|2` 都归并为 `Hard`、`4|5` 都归并为 `Easy`。旧实现只存枚举，
// `to_jsonl` 写回代表值 2/5，于是原文 `1` 变 `2`、`4` 变 `5`：
//
//     {"card_id":"c1",...,"grade":4,...}
//     → from_jsonl → to_jsonl
//     {"card_id":"c1",...,"grade":5,...}      ← 原始值未被保留
//
// 申报承诺「无损复习日志」，评分值有损即核心承诺违约（组委会驳回意见）。
//
// ## 修复
//
// `ReviewEvent` 增加 `grade_raw`（原始评分整数）：`from_jsonl` 经
// `new_with_raw` 记录原文，`to_jsonl` 写回原文；调度语义仍由归一化后的
// `grade` 枚举驱动（1 与 2 调度行为相同是 FSRS/SM-2 的定义，不因日志
// 保真而改变）。非 JSONL 构造（`new`）没有「原文」可保，取代表值。

///|
/// 0..5 全档 + 越界值的往返逐字节断言。
test "RJ-R: grade 原文 0..5 经 from_jsonl → to_jsonl 逐字保留" {
  for g in [0, 1, 2, 3, 4, 5] {
    let line = "{\"card_id\":\"c1\",\"reviewed_at\":1700000000,\"due_at\":1699999509,\"grade\":\{g},\"elapsed_days\":1.0}"
    let log = match ReviewLog::from_jsonl(line) {
      Ok(l) => l
      Err(_) => fail("grade \{g}: parse failed")
    }
    let out = log.to_jsonl()
    inspect(
      out,
      content=line.replace(old="\"elapsed_days\":1.0", new="\"elapsed_days\":1") +
        "\n",
    )
  }
}

///|
test "RJ-R: 越界 grade 的夹取值也不升级（-3 → -3、9 → 9 原样写回）" {
  // from_int 把 -3 夹成 Again、9 夹成 Easy（调度语义）；
  // 但 grade_raw 记录原文，to_jsonl 原样写回 —— 用户写什么就存什么。
  for (raw, _) in [(-3, "Again"), (9, "Easy")] {
    let line = "{\"card_id\":\"c1\",\"reviewed_at\":1700000000,\"due_at\":1699999509,\"grade\":\{raw},\"elapsed_days\":1.0}"
    let log = match ReviewLog::from_jsonl(line) {
      Ok(l) => l
      Err(_) => fail("grade \{raw}: parse failed")
    }
    // 调度枚举取夹取后的档位（行为不变）
    let g = log.events[0].grade
    let _ = Grade::label(g)
    // 写回是原文
    inspect(
      log.to_jsonl(),
      content=line.replace(old="\"elapsed_days\":1.0", new="\"elapsed_days\":1") +
        "\n",
    )
  }
}

///|
test "RJ-R: 非整数小数评分 round 成整数后写回该整数" {
  // "grade":4.6 → round 5 → 写回 5（评分是整数刻度，小数输入本身不合法，
  // round 是文档化的归一；这里锁定 round 后的整数原样保留）
  let line = "{\"card_id\":\"c1\",\"reviewed_at\":1700000000,\"due_at\":1699999509,\"grade\":4.6,\"elapsed_days\":1.0}"
  let log = match ReviewLog::from_jsonl(line) {
    Ok(l) => l
    Err(_) => fail("parse failed")
  }
  inspect(
    log.to_jsonl(),
    content="{\"card_id\":\"c1\",\"reviewed_at\":1700000000,\"due_at\":1699999509,\"grade\":5,\"elapsed_days\":1}\n",
  )
}

///|
test "RJ-R: 调度行为不受 grade_raw 影响（1 与 2 同为 Hard）" {
  // 日志保真不得改变调度语义：grade 1 与 2 都归并为 Hard，重放结果一致
  let line1 = "{\"card_id\":\"c1\",\"reviewed_at\":100,\"due_at\":0,\"grade\":1,\"elapsed_days\":1.0}"
  let line2 = "{\"card_id\":\"c1\",\"reviewed_at\":100,\"due_at\":0,\"grade\":2,\"elapsed_days\":1.0}"
  let log1 = ReviewLog::from_jsonl(line1).unwrap()
  let log2 = ReviewLog::from_jsonl(line2).unwrap()
  inspect(Grade::label(log1.events[0].grade), content="hard")
  inspect(Grade::label(log2.events[0].grade), content="hard")
  // 写回各自原文（这才是保真）
  inspect(log1.to_jsonl().contains("\"grade\":1"), content="true")
  inspect(log2.to_jsonl().contains("\"grade\":2"), content="true")
}
