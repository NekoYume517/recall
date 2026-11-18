///|
/// 2026-11-19 对抗性审查：pub(all) 直构的负 elapsed_days 绕过构造器夹取。
///
/// `ReviewEvent::new/new_with_raw` 与 JSONL 读入口都会把负间隔落成 0，但
/// `event_to_json` 此前只兜住非有限值。直接构造公开字段后，to_jsonl 写出
/// 负数，from_jsonl 再读成 0：写出口与两个入口语义不一致，往返改变事件。
fn negative_elapsed_log() -> ReviewLog {
  let log = ReviewLog::new()
  log.push({
    card_id: "c1",
    reviewed_at: 100L,
    due_at: 40L,
    grade: Good,
    elapsed_days: -3.0,
    grade_raw: 3L,
  })
  log
}

///|
test "to_jsonl: pub(all) 直构的负 elapsed_days 与构造器一样落 0" {
  inspect(
    negative_elapsed_log().to_jsonl(),
    content="{\"card_id\":\"c1\",\"reviewed_at\":100,\"due_at\":40,\"grade\":3,\"elapsed_days\":0}\n",
  )
}

///|
test "to_jsonl/from_jsonl: 负 elapsed_days 规范化后逐字段往返" {
  let text = negative_elapsed_log().to_jsonl()
  let restored = match ReviewLog::from_jsonl(text) {
    Ok(log) => log
    Err(_) => fail("normalized JSONL should parse")
  }
  inspect(restored.events[0].elapsed_days, content="0")
  inspect(restored.to_jsonl() == text, content="true")
}
