///|
/// 审计回归（第十三轮，P2）：`to_jsonl` 会写出 `NaN` / `Infinity`。
///
/// ## 现象
///
/// `ReviewEvent` 的两个公开构造器只把**负数** `elapsed_days` 夹到 0
/// （「负数在物理上无意义」），非有限值原样进事件，`to_jsonl` 又把它们
/// 原样写出：
///
/// ```
/// ReviewEvent::new("c1", 100, 90, Good, 0.0 / 0.0)
/// to_jsonl() -> {"card_id":"c1",...,"elapsed_days":NaN}
/// ```
///
/// `NaN` / `Infinity` **不是 JSON 字面量**，所以这份输出既不能被任何
/// JSON 解析器读，也不能被本仓库自己的 `from_jsonl` 读回（读入口有守卫，
/// 见 `log.mbt` 的 `field_double`：非有限一律 `BadLine`）。
/// 一份自己写得出、自己读不回的文件是静默数据损坏：`replay` / `stats`
/// 在内存里照跑，落盘后就永久读不回来了。
///
/// ## 根因
///
/// 「`elapsed_days` 必须有限」这条判断只写在**读入口**（`field_double`，
/// 第十二轮 `ffe0a27` 同族），**写出口**（`event_to_json`）把浮点直接
/// `Json::number` 出去。与 `fmt_json_number`（CLI 的 JSON 出口统一守卫）
/// 是同一条修法在另一层上的缺口。
///
/// ## 为什么修在写出口而不是构造器
///
/// `ReviewEvent` 是 `pub(all)`，调用方可以完全绕过 `new` / `new_with_raw`
/// 直接构造字段（DISCIPLINE §5.4）。只有序列化出口能覆盖全部事件——
/// 与 `fmt_json_number`「通用的序列化层守卫，不是给某一个字段打补丁」同一判断。

///|
fn log_with_elapsed(values : Array[Double]) -> ReviewLog {
  let log = ReviewLog::new()
  let mut t = 0L
  for v in values {
    log.push(ReviewEvent::new("c1", t, t - 60L, Grade::Good, v))
    t = t + 86400L
  }
  log
}

///|
test "R13-2: NaN / ±Infinity 的 elapsed_days 不再被原样写进 JSONL" {
  let log = log_with_elapsed([1.0, 0.0 / 0.0, 1.0 / 0.0, -1.0 / 0.0, 2.0])
  let text = log.to_jsonl()
  assert_true(!text.contains("NaN"))
  assert_true(!text.contains("Infinity"))
  // 最直接的判据：写出来的东西必须能被自己的 parser 读回。
  let parsed = ReviewLog::from_jsonl(text) catch {
    _ => fail("to_jsonl 的输出无法被 from_jsonl 读回（raise）")
  }
  match parsed {
    Ok(back) => {
      inspect(back.length(), content="5")
      // 非有限值落 0，有限值逐位保留。
      inspect(back.events[0].elapsed_days, content="1")
      inspect(back.events[1].elapsed_days, content="0")
      inspect(back.events[2].elapsed_days, content="0")
      inspect(back.events[3].elapsed_days, content="0")
      inspect(back.events[4].elapsed_days, content="2")
    }
    Err(_) => fail("to_jsonl 的输出被 from_jsonl 判为坏行")
  }
}

///|
test "R13-2: 落 0 不改变任何下游语义（与内存里那份非有限值同口径）" {
  // `review_interval` / `replay` 对非有限 elapsed 的判定都是「不 > 0.0」，
  // 因此 NaN 与 0 在 stats / replay 上等价；写完再读回来必须还是等价。
  let bad = log_with_elapsed([0.0 / 0.0, 5.0])
  let zero = log_with_elapsed([0.0, 5.0])
  let sb = compute_stats(bad)
  let sz = compute_stats(zero)
  inspect(sb.length(), content="1")
  inspect(sz.length(), content="1")
  inspect(sb[0].reviews, content="2")
  assert_true(approx_default(sb[0].mean_interval, sz[0].mean_interval))
  assert_true(approx_default(sb[0].max_interval, sz[0].max_interval))
  assert_true(approx_default(sb[0].mean_interval, 5.0))
  // 写出去再读回来，仍然与内存里那份等价。
  let round = ReviewLog::from_jsonl(bad.to_jsonl()) catch {
    _ => fail("roundtrip 读回失败")
  }
  match round {
    Ok(back) => {
      let sr = compute_stats(back)
      assert_true(approx_default(sr[0].mean_interval, sz[0].mean_interval))
    }
    Err(_) => fail("roundtrip 被拒")
  }
}

///|
test "R13-2: 有限 elapsed_days 的输出逐字节不变（防过度收紧）" {
  let log = log_with_elapsed([0.0, 1.0, 3.0, 8.5])
  inspect(
    log.to_jsonl(),
    content="{\"card_id\":\"c1\",\"reviewed_at\":0,\"due_at\":-60,\"grade\":3,\"elapsed_days\":0}\n" +
      "{\"card_id\":\"c1\",\"reviewed_at\":86400,\"due_at\":86340,\"grade\":3,\"elapsed_days\":1}\n" +
      "{\"card_id\":\"c1\",\"reviewed_at\":172800,\"due_at\":172740,\"grade\":3,\"elapsed_days\":3}\n" +
      "{\"card_id\":\"c1\",\"reviewed_at\":259200,\"due_at\":259140,\"grade\":3,\"elapsed_days\":8.5}\n",
  )
}

///|
test "R13-2: 负数仍按构造器约定夹到 0（既有行为不变）" {
  let log = log_with_elapsed([-3.0])
  inspect(log.events[0].elapsed_days, content="0")
  inspect(
    log.to_jsonl(),
    content="{\"card_id\":\"c1\",\"reviewed_at\":0,\"due_at\":-60,\"grade\":3,\"elapsed_days\":0}\n",
  )
}
