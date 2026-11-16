///|
/// 非零值在指定小数位下会舍成零时，不能把曲线桶沿显示成 0.0000。
/// 与大数定点溢出一样，退回 Double 的短科学计数法保持数量级可见。
test "fmt_float: 正次正规数不会被格式化成零" {
  let text = fmt_float(5.0e-324, 4)
  assert_true(text != "0.0000")
  assert_true(text.contains("e"))
}

///|
test "fmt_float: 负小值保留符号，真正的零仍按定点显示" {
  let text = fmt_float(-5.0e-324, 4)
  assert_true(text != "0.0000")
  assert_true(text != "-0.0000")
  assert_true(text.contains("e"))
  assert_eq(fmt_float(0.0, 4), "0.0000")
}

///|
test "fmt_float: 可在请求精度内区分的普通值仍按定点显示" {
  assert_eq(fmt_float(0.00009, 4), "0.0001")
  assert_eq(fmt_float(1.25, 2), "1.25")
}
