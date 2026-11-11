///|
/// 参数行里的「目标保持率」必须等于**生效值**（R-3，2026-11-11 审计）。
///
/// 修复前非 FSRS 调度器也把请求值原样打出来，紧邻的两行自相矛盾：
///
/// ```
/// 提示: sm2 调度器没有目标保持率参数（算法局限），--retention 0.70 未生效（仅 FSRS 支持）
/// 参数: 5 天, 每天新增 5 张, 复习上限 200, 目标保持率 0.70, 种子 20240101
/// ```
///
/// 这与项目已经修过的 R1（打印值必须等于生效值）同类，只是当时只修了 FSRS
/// 的越界夹取分支。`simulate` 与 `advice` 两个子命令共用这里的格式化函数。
test "retention_field_text: 非 fsrs 打印 n/a 而不是未生效的请求值" {
  // 生效值的计算没变（非 fsrs 原样透传），变的是**打印**
  assert_eq(effective_retention("sm2", 0.7), 0.7)
  assert_eq(effective_retention("leitner", 0.95), 0.95)
  // fsrs：打印生效值（越界时是夹取后的值）
  assert_eq(retention_field_text("fsrs", 0.7), "0.70")
  assert_eq(retention_field_text("fsrs", 0.5), "0.50")
  assert_eq(retention_field_text("fsrs", 0.99), "0.99")
  // 非 fsrs：n/a，且与请求值无关
  let sm2 = retention_field_text("sm2", 0.7)
  assert_true(sm2.contains("n/a"))
  assert_true(!sm2.contains("0.7"))
  assert_eq(sm2, retention_field_text("sm2", 0.9))
  assert_true(retention_field_text("leitner", 0.95).contains("n/a"))
}
