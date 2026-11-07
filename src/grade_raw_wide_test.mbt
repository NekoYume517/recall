// RJ-1b（2026-11-08 审计）：grade_raw 用 Int32 承载「原文」，超域整数
// 首次往返即非恒等 —— 组委会驳回的「评分值往返改变」在更大数值域复发。
//
// ## 缺陷形态（修复前）
//
//     {"card_id":"c1",...,"grade":2500000000,...}
//     → from_jsonl → to_jsonl
//     {"card_id":"c1",...,"grade":2147483647,...}   ← Int32 饱和
//
// 根因：event_from_line 的 `@math.round(grade_num).to_int()` 把超 Int32
// 的值饱和到 ±2^31-1；grade_raw : Int32 本身装不下原文。API.md §2 的
// 「from_jsonl(to_jsonl(log)) 逐字节恒等」承诺对超 Int32 的 grade 失效。
// e395446 的回归只测了 -3/9（Int32 内），大数路径无覆盖。
//
// ## 修复
//
// grade_raw 从 Int32 扩为 Int64：JSON 数字是 Double，Int64 能无损承载
// 到 2^53；调度语义（Grade 枚举 + from_int 归一化）零变化。ReviewEvent
// 是 pub(all)，字段类型变更属破坏性 ABI 变化 —— 本仓库尚在 0.x、无
// 下游用户，直接改字段类型而不是新增旁路字段。

///|
test "RJ-1b: 超出 Int32 的 grade 原文逐字保留" {
  let line = "{\"card_id\":\"c1\",\"reviewed_at\":100,\"due_at\":0,\"grade\":2500000000,\"elapsed_days\":1}"
  let log = match ReviewLog::from_jsonl(line) {
    Ok(l) => l
    Err(_) => fail("parse failed")
  }
  inspect(
    log.to_jsonl(),
    content="{\"card_id\":\"c1\",\"reviewed_at\":100,\"due_at\":0,\"grade\":2500000000,\"elapsed_days\":1}\n",
  )
  // 调度档位仍取归一化结果（2500000000 → Easy）
  inspect(log.events[0].grade is Easy, content="true")
}

///|
test "RJ-1b: 负向超域 grade 原文逐字保留" {
  let line = "{\"card_id\":\"c1\",\"reviewed_at\":100,\"due_at\":0,\"grade\":-9999999999,\"elapsed_days\":1}"
  let log = match ReviewLog::from_jsonl(line) {
    Ok(l) => l
    Err(_) => fail("parse failed")
  }
  inspect(
    log.to_jsonl(),
    content="{\"card_id\":\"c1\",\"reviewed_at\":100,\"due_at\":0,\"grade\":-9999999999,\"elapsed_days\":1}\n",
  )
}

///|
test "RJ-1b: Int64 也不能承载的 grade 拒收而不是静默饱和" {
  // 1e20 已超出 Double 的精确整数域（2^53），round 后无法无损承载 ——
  // 与 elapsed_days 的有限性原则一致：装不下就报错，不静默改值。
  let line = "{\"card_id\":\"c1\",\"reviewed_at\":100,\"due_at\":0,\"grade\":100000000000000000000,\"elapsed_days\":1}"
  let r = ReviewLog::from_jsonl(line)
  inspect(r is Err(_), content="true")
}
