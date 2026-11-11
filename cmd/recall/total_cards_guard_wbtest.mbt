///|
/// 审计回归（2026-11-12）：`simulate` 的**乘积**守卫。
///
/// 三个单轴守卫各管一维，成本却是 `days × new_per_day` 的乘积。实测
/// `--days 100000 --new-per-day 200`（2000 万张卡）两轴都在守卫内：进程不崩、
/// 不报错、60 s 没有任何输出也不退出——比崩溃更难诊断。
///
/// 这条用例只测守卫函数本身（纯函数、可精确断言边界），端到端由 CLI 手工验过，
/// 记录在 `audit/2026-11-12/recall/REPORT.md`。

///|
test "total cards guard: the documented boundary is still allowed" {
  // N-3 用的就是 days=1 × new_per_day=100000，乘积正好 100000，必须放行。
  inspect(total_cards_error(1, 100000), content="")
  inspect(total_cards_error(100000, 1), content="")
  inspect(total_cards_error(90, 20), content="")
  inspect(total_cards_error(0, 20), content="")
}

///|
test "total cards guard: two legal axes can still multiply past the bound" {
  let msg = total_cards_error(100000, 200)
  assert_true(msg.contains("100000"))
  assert_true(msg.contains("20000000"))
}

///|
test "total cards guard: the product is computed in 64 bits" {
  // 100000 × 100000 = 1e10：Int32 里会绕成 1410065408（正数，守卫会放行），
  // Int64 里就是 10000000000。消息里必须出现真值，这是「守卫自己没绕」的证据。
  let msg = total_cards_error(100000, 100000)
  assert_true(msg.contains("10000000000"))
}
