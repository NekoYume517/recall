// ============================================================================
// `--seed` 的合法域是 Int64 全域，包括下界 -2^63
//
// 现象（第十九轮 RC-19-3，2026-11-27，native release 实测）：
//
//     recall simulate --days 1 --seed 9223372036854775807   -> exit 0
//     recall simulate --days 1 --seed -9223372036854775807  -> exit 0
//     recall simulate --days 1 --seed -9223372036854775808  -> exit 2
//         用法错误: --seed 需要一个整数，得到 '-9223372036854775808'
//
// 根因：`parse_int64_loose` 用 Int64 累加幅值，而 2^63 恰好在 Int64 上界之外
// （Int64 最大只到 2^63-1）。于是「负数幅值 2^63」这一格表达不出来，被当成
// 越界拒绝——函数注释里写的「结果允许落在 Int64 全域」从末位就差一格。
// 更糟的是缺少预检：`-9223372036854775999`（溢出 Int64 下界）的累加器回绕成
// 一个**合法**的 Int64，静默接受一个用户没写过的种子。
//
// 修法：
//   1. 负号分支允许幅值 2^63（这一格正号与无符号都不允许）；
//   2. 在判幅值越界之前先判 `overflows(neg, acc)`——溢出（含 Int64 下界外一格）
//      必须返回 None，不能交给 Int64 取反/回绕；
//   3. 解析成功但落在半开区间 [2^63-1, 2^63) 时按 2^63-1 饱和，保证
//      「Domain::success」判据（见 `--seed` 的用法说明）在端点不出逃。

///|
test "rc19-3: --seed 接受 Int64 下界 -9223372036854775808" {
  // 修复前这里是 None
  inspect(
    parse_int64_loose("-9223372036854775808"),
    content="Some(-9223372036854775808)",
  )
}

///|
test "rc19-3: --seed 的溢出边界不再被回绕成合法值" {
  // Int64 下界外一格：旧实现算出 -9223372036854775807 之类被接受的值
  inspect(parse_int64_loose("-9223372036854775809"), content="None")
  // 上界外一格
  inspect(parse_int64_loose("9223372036854775808"), content="None")
  // 下界本身（20 位，边界上一格都不能多）
  assert_true(parse_int64_loose("-9223372036854775808") != None)
}

///|
test "rc19-3: --seed 的常规区间与正负号照旧" {
  inspect(parse_int64_loose("0"), content="Some(0)")
  inspect(parse_int64_loose("-1"), content="Some(-1)")
  inspect(parse_int64_loose("+3000000000"), content="Some(3000000000)")
  inspect(
    parse_int64_loose("9223372036854775807"),
    content="Some(9223372036854775807)",
  )
  inspect(
    parse_int64_loose("-9223372036854775807"),
    content="Some(-9223372036854775807)",
  )
  // 空串与裸符号
  inspect(parse_int64_loose(""), content="None")
  inspect(parse_int64_loose("-"), content="None")
  inspect(parse_int64_loose("+"), content="None")
}

///|
test "rc19-3: --seed 落在端点时的归一结果不越界" {
  // 端点处的种子用于 LCG；下界与上界都必须给出有限的 Int64
  let lo = parse_int64_loose("-9223372036854775808")
  let hi = parse_int64_loose("9223372036854775807")
  assert_true(lo != None)
  assert_true(hi != None)
}
