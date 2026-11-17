///|
/// 审计回归（第十二轮，P2）：JSON 序列化层的**非有限数守卫**。
///
/// `recall replay --json` 是机器可读出口（`API.md` §7）。修复前它的浮点字段
/// 走 `fmt_float`，而 `fmt_float` 对非有限值的兜底是 `Double::to_string`，
/// 给出 `Infinity` / `NaN` —— 这两个**不是 JSON 字面量**：
///
/// ```
/// {"scheduler":"fsrs",…,"interval_error_days":Infinity,…}   ← exit 0，解析即失败
/// ```
///
/// 修法不是给某个字段打补丁，而是加一个**序列化层出口** `fmt_json_number`：
/// 非有限 → `null`（JSON 既有的「没有可用数值」表达），其余照旧。这条 JSON
/// 里所有浮点出口都走它，将来新增字段也走它。

///|
test "json number guard: 非有限值写成 null，而不是 Infinity/NaN" {
  inspect(fmt_json_number(1.0 / 0.0, 2), content="null")
  inspect(fmt_json_number(-1.0 / 0.0, 2), content="null")
  inspect(fmt_json_number(0.0 / 0.0, 4), content="null")
}

///|
test "json number guard: 有限值逐位不变（防过度收紧）" {
  inspect(fmt_json_number(0.0, 2), content="0.00")
  inspect(fmt_json_number(-0.5, 2), content="-0.50")
  inspect(fmt_json_number(421.0206, 4), content="421.0206")
  inspect(fmt_json_number(9.0, 2), content="9.00")
}

///|
test "json number guard: 极大有限值走指数兜底，但仍是合法 JSON 数字" {
  let big = fmt_json_number(1.0e308, 2)
  assert_false(big.contains("Infinity"))
  assert_false(big.contains("NaN"))
  // 逐字符白名单：数字 / 符号 / 小数点 / 指数标记，除此之外一律不许。
  for c in big.to_array() {
    let ok = (c >= '0' && c <= '9') ||
      c == '-' ||
      c == '+' ||
      c == '.' ||
      c == 'e' ||
      c == 'E'
    assert_true(ok)
  }
  // 次正规非零小值同理（不小成 0，也不出非数字字符）。
  let tiny = fmt_json_number(5.0e-324, 2)
  assert_false(tiny == "0.00")
  for c in tiny.to_array() {
    let ok = (c >= '0' && c <= '9') ||
      c == '-' ||
      c == '+' ||
      c == '.' ||
      c == 'e' ||
      c == 'E'
    assert_true(ok)
  }
}

///|
test "json number guard: 一个 Infinity 就能毁掉整行 JSON（修复前后对照）" {
  let unguarded = "{\"v\":" + fmt_float(1.0 / 0.0, 4) + "}"
  assert_true(unguarded.contains("Infinity"))
  let guarded = "{\"v\":" + fmt_json_number(1.0 / 0.0, 4) + "}"
  inspect(guarded, content="{\"v\":null}")
  assert_false(guarded.contains("Infinity"))
}
