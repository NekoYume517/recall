// 回归：JSONL grade 在 (2^31, 2^53] 区间时的 Int64→Int32 截断。
//
// 修复前 `Grade::from_int(@math.round(grade_num).to_int())` 先把 Int64
// 截断成 Int32：4294967297（= 2^32 + 1，≤ 2^53、合法输入）低 32 位
// 绕回成 1 → Hard；-4294967294 绕回成 2 → Hard。而 types.mbt 的
// `Grade::from_int` 文档承诺「负数按 0、>5 按 5 处理」——即应分别是
// Easy / Again。此前的 ±2^53 端点用例恰好绕回后仍是端点代表分，
// 漏掉了这一档。
//
// 调度语义由 grade 枚举驱动，截断错档会让中间层级的巨型 grade
// 被当成 Hard（答对但最小前进）而不是 Easy（最大前进）。

///|
test "grade 2^32+1 应夹成 Easy 而不是截断成 Hard" {
  let line = "{\"card_id\":\"c1\",\"reviewed_at\":1700000000,\"due_at\":1699999000,\"grade\":4294967297,\"elapsed_days\":1}"
  let log = match ReviewLog::from_jsonl(line) {
    Ok(l) => l
    Err(_) => fail("parse failed")
  }
  let ev = log.events[0]
  guard ev.grade == Easy
  // grade_raw 无损保留原文
  guard ev.grade_raw == 4294967297L
}

///|
test "grade -(2^32-2) 应夹成 Again 而不是截断成 Hard" {
  let line = "{\"card_id\":\"c1\",\"reviewed_at\":1700000000,\"due_at\":1699999000,\"grade\":-4294967294,\"elapsed_days\":1}"
  let log = match ReviewLog::from_jsonl(line) {
    Ok(l) => l
    Err(_) => fail("parse failed")
  }
  let ev = log.events[0]
  guard ev.grade == Again
  guard ev.grade_raw == -4294967294L
}

///|
test "区间内 grade 的 round 归一化不受夹取影响" {
  // 1.5 → 2（Hard）是文档化行为，修复不得改变它
  let line = "{\"card_id\":\"c1\",\"reviewed_at\":1700000000,\"due_at\":1699999000,\"grade\":1.5,\"elapsed_days\":1}"
  let log = match ReviewLog::from_jsonl(line) {
    Ok(l) => l
    Err(_) => fail("parse failed")
  }
  guard log.events[0].grade == Hard
  guard log.events[0].grade_raw == 2L
}
