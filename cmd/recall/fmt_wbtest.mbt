// 回归测试：fmt_float 的定点换算用 Int64 承载（rounded/scale），
// 超出 Int64 表示范围时会静默饱和成 92233720368547758.07 这类
// 无意义数字，并把表格列宽撑爆。合法输入（elapsed_days 允许任意
// 有限 Double，如 1e300）必须给出诚实输出，而不是饱和垃圾值。

///|
test "fmt_float: 超大有限值不得饱和成 Int64 定点垃圾" {
  let out = fmt_float(1.0e300, 2)
  // 不允许出现 Int64 饱和前缀（饱和时会打印 92233720368547758.xx）
  assert_false(out.contains("922337"))
  // 输出必须是诚实的量级表示（指数形式），且长度受控
  inspect(out, content="1e+300")
}

///|
test "fmt_float: v*scale 超出 Int64 但 v 本身可表示时走指数形式" {
  // 1e18 * 100 = 1e20 > Int64 max，定点路径必炸；退回 Double 字符串化
  inspect(fmt_float(1.0e18, 2), content="1000000000000000000")
}

///|
test "fmt_float: 常规值不受防护分支影响" {
  inspect(fmt_float(0.9123, 2), content="0.91")
  inspect(fmt_float(13371.0, 1), content="13371.0")
  inspect(fmt_float(-0.25, 2), content="-0.25")
  inspect(fmt_float(0.0, 2), content="0.00")
  // Int64 内的最大正常定点值仍然走定点路径
  inspect(fmt_float(9.2e16, 0), content="92000000000000000")
}

///|
test "fmt_float: NaN 走防护分支而不是打印垃圾" {
  let out = fmt_float(0.0 / 0.0, 2)
  assert_false(out.contains("922337"))
}
