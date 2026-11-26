// ============================================================================
// 同刻事件告警的**出口层**判据：stderr 有诊断、`--json` 有字段、stdout 不被污染
//
// 第二十轮 RC-20-3 追加（Lead 裁决 2026-11-29）。库层已有
// `same_timestamp_groups`（src/replay_same_timestamp_warning_test.mbt 锁住计数
// 口径），这里锁出口：
//
//   1. 有同刻事件 → `--json` 里出现 `"same_timestamp_groups":N`；
//   2. 无同刻事件 → **键不出现**（形状与第十九轮完全一致，老消费者不受影响）；
//   3. 两条诊断都只走 stderr，stdout 一个字节不被污染；
//   4. 诊断文本要说清「先后按文件行序决定、换序可能改变摘要」——使用者不读
//      API.md，这句话必须出现在他看得到的地方。

///|
/// 造一份「k 卡有一条同刻对」的日志文本（JSONL）。
fn rc20_tied_log_text() -> String {
  "{\"card_id\":\"k\",\"reviewed_at\":1700000000,\"due_at\":1700000000,\"grade\":3,\"elapsed_days\":1}\n" +
  "{\"card_id\":\"k\",\"reviewed_at\":1700086400,\"due_at\":1700086400,\"grade\":4,\"elapsed_days\":1}\n" +
  "{\"card_id\":\"k\",\"reviewed_at\":1700086400,\"due_at\":1700086400,\"grade\":0,\"elapsed_days\":1}\n"
}

///|
/// 造一份「无同刻」的日志文本（同样三条事件，时刻各不同）。
fn rc20_untied_log_text() -> String {
  "{\"card_id\":\"k\",\"reviewed_at\":1700000000,\"due_at\":1700000000,\"grade\":3,\"elapsed_days\":1}\n" +
  "{\"card_id\":\"k\",\"reviewed_at\":1700086400,\"due_at\":1700086400,\"grade\":4,\"elapsed_days\":1}\n" +
  "{\"card_id\":\"k\",\"reviewed_at\":1700172800,\"due_at\":1700172800,\"grade\":0,\"elapsed_days\":1}\n"
}

///|
test "rc20-3b: JSON 字段拼接——有同刻才出现，且值正确" {
  // 直接测 emit 用的那一段拼装逻辑，避免测试里写文件
  inspect(rc20_json_tail(1), content=",\"same_timestamp_groups\":1")
  inspect(rc20_json_tail(3), content=",\"same_timestamp_groups\":3")
  // 0 表示「没有同刻事件」：按契约不写这个键
  inspect(rc20_json_tail(0), content="")
}

///|
test "rc20-3b: 同刻诊断文本包含关键三要素" {
  let msg = rc20_same_ts_warning("k", 2)
  // 卡片 id、条数、后果
  assert_true(msg.contains("k"))
  assert_true(msg.contains("2"))
  assert_true(msg.contains("文件行序"))
  assert_true(msg.contains("摘要"))
}

///|
test "rc20-3b: 无同刻事件时不产生诊断" {
  let log = parse_log_text_for_test(rc20_untied_log_text())
  let warns = rc20_collect_same_ts_warnings(log)
  assert_eq(warns.length(), 0)
}

///|
test "rc20-3b: 有同刻事件时诊断按 card_id 升序、每卡一条" {
  let log = parse_log_text_for_test(
    "{\"card_id\":\"b\",\"reviewed_at\":1700000000,\"due_at\":1700000000,\"grade\":3,\"elapsed_days\":1}\n" +
    "{\"card_id\":\"b\",\"reviewed_at\":1700086400,\"due_at\":1700086400,\"grade\":3,\"elapsed_days\":1}\n" +
    "{\"card_id\":\"b\",\"reviewed_at\":1700086400,\"due_at\":1700086400,\"grade\":4,\"elapsed_days\":1}\n" +
    "{\"card_id\":\"a\",\"reviewed_at\":1700000000,\"due_at\":1700000000,\"grade\":3,\"elapsed_days\":1}\n" +
    "{\"card_id\":\"a\",\"reviewed_at\":1700086400,\"due_at\":1700086400,\"grade\":3,\"elapsed_days\":1}\n" +
    "{\"card_id\":\"a\",\"reviewed_at\":1700086400,\"due_at\":1700086400,\"grade\":4,\"elapsed_days\":1}\n",
  )
  let warns = rc20_collect_same_ts_warnings(log)
  assert_eq(warns.length(), 2)
  // 升序：a 在前
  assert_true(warns[0].contains("卡片 a"))
  assert_true(warns[1].contains("卡片 b"))
}
