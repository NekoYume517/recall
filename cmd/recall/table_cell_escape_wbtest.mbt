///|
/// 审计回归（第十七轮 F2，2026-11-24）：**控制台表格不能吃原始控制字符**。
///
/// 现象（修前实测）：日志里 `card_id` 是 `"a\nb"`（JSON 里合法，Anki 卡号带
/// 换行很常见）时，`recall stats` 把一张卡打成两行：
///
///     卡片                  复习      遗忘  ...
///     a
///     b                  2       0    ...
///     z                    1       0    ...
///
/// 后果三条：①「一张卡一行」这个表格契约没了，`awk`/`cut` 数行数的脚本错位；
/// ② 制表符会把整行推到下一个 TAB 位；③ `\u001B[2J` 这类 ANSI 序列能清屏、
/// 改色、伪造提示——日志是不可信输入。
///
/// 根因：`pad_right` / `pad_left` 把字符串原样拼进表格。`--json` 走 Json 转义、
/// `--anki` 走 CSV 引号规则，各有守卫，只有控制台表格这第三个出口是裸的。
///
/// 修法：`cell_text` 一个权威实现（控制字符转义成可见形式，宽度按转义后算），
/// `pad_right` / `pad_left` 都过它。

///|
test "table cell: 卡号里的换行不会把一张卡拆成两行" {
  let cell = pad_right("a\nb", 10)
  assert_false(cell.contains("\n"))
  assert_true(cell.contains("a\\nb"))
  assert_eq(cell.length(), 10)
}

///|
test "table cell: 回车与制表符都转义，列宽按转义后算" {
  let cell = pad_right("a\tb\rc", 12)
  assert_false(cell.contains("\t"))
  assert_false(cell.contains("\r"))
  assert_true(cell.contains("a\\tb\\rc"))
  assert_eq(cell.length(), 12)
}

///|
test "table cell: ANSI 转义序列不原样进终端" {
  let cell = pad_right("\u{1B}[31mred", 14)
  assert_false(cell.contains("\u{1B}"))
  assert_true(cell.contains("\\u001B"))
  assert_true(cell.contains("[31mred"))
}

///|
test "table cell: 其余 C0/C1 控制字符按 \\uXXXX 显示" {
  assert_eq(cell_text("\u{0}"), "\\u0000")
  assert_eq(cell_text("\u{7F}"), "\\u007F")
  assert_eq(cell_text("\u{9B}"), "\\u009B")
}

///|
test "table cell: 普通卡号逐字不变（不动既有输出）" {
  assert_eq(cell_text("c1"), "c1")
  assert_eq(cell_text("卡片"), "卡片")
  assert_eq(pad_right("c1", 6), "c1    ")
  assert_eq(pad_left("c1", 6), "    c1")
  assert_eq(pad_right("卡片", 12).length(), 12)
  // 正好占满宽度时不多补空格（边界）
  assert_eq(pad_right("abcd", 4), "abcd")
  assert_eq(pad_left("abcd", 4), "abcd")
}
