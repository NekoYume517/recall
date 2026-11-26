// 辅助：把 JSONL 文本喂给库层解析，供「同刻事件告警」的用例使用。
//
// `from_jsonl` 是 `raise` 型（`Result[ReviewLog, LogError] raise`），所以辅助函数
// 自己也要声明 `raise`——与 src/audit_round6_test.mbt 里 `rja4_parse` 的写法一致。

///|
fn parse_log_text_for_test(text : String) -> @lib.ReviewLog raise {
  match @lib.ReviewLog::from_jsonl(text) {
    Ok(log) => log
    Err(_) => abort("test fixture parse failed")
  }
}

///|
fn rc20_collect_same_ts_warnings(log : @lib.ReviewLog) -> Array[String] {
  rc20_same_ts_messages(log)
}
