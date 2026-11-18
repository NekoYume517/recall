///|
/// 2026-11-19 对抗性审查：Int64 grade_raw 的写出口越过 JSON 精确整数域。
///
/// from_jsonl 明确拒收 |grade| > 2^53，避免 Double 把相邻整数合并；但公开
/// new_with_raw / pub(all) 字段可放入 Int64.MAX/MIN，event_to_json 又直接
/// to_double。旧输出既改变原值，也无法被自己的 from_jsonl 读回。
fn wide_grade_event(raw : Int64, grade : Grade) -> ReviewEvent {
  ReviewEvent::new_with_raw("c", 100L, 40L, grade, raw, 1.0)
}

///|
test "to_jsonl: 超 JSON 精确整数域的 grade_raw 规范化后可读回" {
  let log = ReviewLog::new()
  log.push(wide_grade_event(9223372036854775807L, Easy))
  log.push(wide_grade_event(-9223372036854775807L, Again))
  let text = log.to_jsonl()
  let restored = match ReviewLog::from_jsonl(text) {
    Ok(value) => value
    Err(_) => fail("serialized wide grades should parse")
  }
  inspect(restored.events[0].grade_raw, content="5")
  inspect(restored.events[1].grade_raw, content="0")
  inspect(restored.to_jsonl() == text, content="true")
}

///|
test "to_jsonl: ±2^53 精确边界仍逐字节保留" {
  let log = ReviewLog::new()
  log.push(wide_grade_event(9007199254740992L, Easy))
  log.push(wide_grade_event(-9007199254740992L, Again))
  let text = log.to_jsonl()
  let restored = match ReviewLog::from_jsonl(text) {
    Ok(value) => value
    Err(_) => fail("exact 2^53 boundary should parse")
  }
  inspect(restored.to_jsonl() == text, content="true")
}
