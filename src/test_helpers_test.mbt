// 共享测试辅助函数
//
// 文件名以 `_test.mbt` 结尾 → MoonBit 按白盒测试处理（同包、不导出），
// 因此这里定义的函数可以被同包所有 `*_test.mbt` 复用，也不会污染库 API。
//
// 为什么不放在某个具体测试文件里：一个包内顶层函数只能定义一次，
// 放在 types_test.mbt 里会让其他测试文件依赖它的存在顺序，很脆。

///|
/// 浮点容差断言。
///
/// 按 MOONBIT-GUIDE 第 10 节坑 B/C：
/// - 不要用 `inspect` 精确比浮点字符串（2.7 会变成 "2.7000000000000003"）
/// - 复合表达式先绑到变量再比较，避免解析器挑错
fn approx(a : Double, b : Double, eps : Double) -> Bool {
  let d = a - b
  d.abs() < eps
}

///|
/// 默认容差（1e-9）。单独成一个函数，避免在测试里重复写 9 个 0。
fn approx_default(a : Double, b : Double) -> Bool {
  approx(a, b, 0.000000001)
}
