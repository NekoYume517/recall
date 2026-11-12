///|
/// 审计回归（2026-11-12 遗留项 A1）：`advice` 的**成本**守卫。
///
/// 单轴守卫各管一维（`--days <= 100000`、`--review-limit <= 100000`），但
/// `advice` 的总成本是两轴的乘积：**探测次数 × 单次模拟**。`load_advice`
/// 从 `hi = review_limit`（0 时取 500）向下逐张探测，最坏 `hi + 2` 次；
/// 每次探测是 `O(days² × n)` 的整段模拟。于是
///
///     recall advice --days 5000 --review-limit 200
///
/// 两轴都在守卫内，真值是 `202 × 5000² × 200 ≈ 1.01e12` 个单位——实测
/// 90 s 零字节输出、不退出（`evidence/a1-pre-days5000-default.log`）。
///
/// 阈值与依据见 `advice_cost_error` 的注释；端到端由 CLI 手工验过，
/// 记录在 `audit/2026-11-12/followup/REPORT.md`。

///|
test "advice cost guard: 默认档与被接受的基线都放行" {
  // 默认档（90 天 / 复习上限 200）：实测 31.8 s，必须仍然跑得动。
  inspect(advice_cost_error(90, 200), content="")
  // API.md §5.1 明文接受的 136 s 基线，不能反过来被新守卫拒掉。
  inspect(advice_cost_error(90, 500), content="")
  // `--review-limit 0`（不限）在 load_advice 里 hi 取固定 500，与上一档同形。
  inspect(advice_cost_error(90, 0), content="")
  // 小预算仍是小预算。
  inspect(advice_cost_error(30, 200), content="")
  inspect(advice_cost_error(90, 1), content="")
}

///|
test "advice cost guard: 两轴都合法也能乘成天文量级" {
  let msg = advice_cost_error(5000, 200)
  // 消息必须给出两轴与乘积，否则用户不知道是哪一轴超了。
  assert_true(msg.contains("5000"))
  assert_true(msg.contains("200"))
  assert_true(msg.contains("1010000000000"))
}

///|
test "advice cost guard: 乘积用 64 位计算，不在 Int32 边界绕成负数" {
  // 100000² 已经 1e10：Int32 里 days*days 先绕，守卫会「放行」。
  // 真值 202 × 100000² × 200 = 4.04e14。
  let msg = advice_cost_error(100000, 200)
  assert_true(msg.contains("404000000000000"))
}

///|
test "advice cost guard: 边界按 `>` 判定，不误伤紧邻的合法值" {
  // 248² × 40400 = 2484761600 <= 2.5e9：放行。
  inspect(advice_cost_error(248, 200), content="")
  // 249² × 40400 = 2504840400 > 2.5e9：拒绝。
  assert_true(advice_cost_error(249, 200).length() > 0)
}

///|
test "advice cost guard: 极端乘积饱和成非负上界，不绕成负数" {
  // 100002 × 100000² × 100000 = 1.00002e20 > Int64::MAX（9.22e18）。
  let msg = advice_cost_error(100000, 100000)
  assert_true(msg.length() > 0)
  // 饱和值必须以正数出现（含「饱和」标注），绝不能是绕出来的负数。
  assert_true(msg.contains("9223372036854775807"))
}

///|
test "advice cost guard: 拒绝消息给出按当前另一轴反算的可行值" {
  // R-7 同族：报错必须给能执行的下一步，否则用户只知道「超了」。
  let msg = advice_cost_error(5000, 200)
  // 固定 --review-limit 200：--days 上界 = floor(sqrt(2.5e9 / (202×200))) = 248
  assert_true(msg.contains("把 --days 降到 248 以内"))
  // 固定 --days 5000：解 h² + 2h <= 2.5e9 / 5000² → h = 9
  assert_true(msg.contains("把 --review-limit 降到 9 以内"))
}

///|
test "advice cost guard: 建议值代回守卫必须真的通过，再大一点必须被拒" {
  // 「建议一个也会被拒的值」是这条修复最容易犯的错：两侧建议都代回判定。
  inspect(advice_cost_error(248, 200), content="")
  inspect(advice_cost_error(5000, 9), content="")
  // 建议值必须是可行的**最大值**，否则建议白白保守。
  assert_true(advice_cost_error(249, 200).length() > 0)
  assert_true(advice_cost_error(5000, 10).length() > 0)
}

///|
test "advice cost guard: --review-limit 0 只建议减天数" {
  // 0 = 不限，hi 取固定 500。此时把 review-limit 改成具体值会改掉「不限」
  // 语义，所以不反算这一侧，如实说只能减 --days。
  let msg = advice_cost_error(5000, 0)
  // floor(sqrt(2.5e9 / (502×500))) = 99
  assert_true(msg.contains("把 --days 降到 99 以内"))
  assert_true(msg.contains("只能减 --days"))
  assert_false(msg.contains("把 --review-limit 降到"))
  inspect(advice_cost_error(99, 0), content="")
}

///|
test "advice cost guard: 两轴都没有单独可行值时如实说明" {
  // days=100000 与 hi=100000 时，单独把任一轴降到 1 仍然超界。
  let msg = advice_cost_error(100000, 100000)
  assert_true(msg.contains("都需调小"))
}
