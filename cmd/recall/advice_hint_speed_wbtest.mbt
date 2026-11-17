///|
/// 审计回归（第十二轮，P3）：`advice` 拒绝消息里的建议值不能是「最慢的一档」。
///
/// ## 现象
///
/// `advice_cost_hint` 反算出的上界**就是成本上限本身**，也就是最慢的一档：
///
/// ```
/// $ recall advice --days 5000 --review-limit 200
/// 用法错误: … 202 × 5000² × 200 = 1010000000000 …
///   建议: 保持 --review-limit 200 时把 --days 降到 248 以内；…
/// $ recall advice --days 248 --review-limit 200        # 照建议改
/// exit 0，耗时 245.96 s（本机 native release）          # ← 4 分 6 秒
/// ```
///
/// §20.6-3 的纪律是「建议值必须代回真跑」，而代回真跑发现它要 4 分钟。
///
/// ## 修法
///
/// 每条建议后标出「上限档 + 成本占比」，并另给一条**同一公式、上限压到 1/8**
/// 的快速档（同样代回判定后才写出）。两侧都只在 `!advice_cost_over(...)` 成立
/// 时出现，所以「建议一个也会被拒的值」这条老纪律仍然被锁住。

///|
test "advice hint: 上限档要如实标出「最慢的一档」与成本占比" {
  let msg = advice_cost_error(5000, 200)
  // 老口径必须保留（既有用例锁的就是这两句）。
  assert_true(msg.contains("把 --days 降到 248 以内"))
  assert_true(msg.contains("把 --review-limit 降到 9 以内"))
  // 新增：告诉用户这是上限档，并给出成本占比。
  assert_true(msg.contains("上限档"))
  assert_true(msg.contains("最慢的一档"))
  // 248 那一档的成本是 202×248²×200 = 2.48e9，占 2.5e9 的 99%。
  assert_true(msg.contains("99%"))
}

///|
test "advice hint: 快速档存在、代回守卫真的通过、且成本不超过上限的 1/8" {
  let msg = advice_cost_error(5000, 200)
  assert_true(msg.contains("更快的一档"))
  // 快速档的 --days：floor(sqrt(3.125e8 / (202×200))) = 87
  assert_true(msg.contains("--days 87"))
  assert_true(msg.contains("1/8"))
  // 代回：87 与 88 必须分别是「放行 / 超快速档」，且 87 仍在主守卫内。
  inspect(advice_cost_error(87, 200), content="")
  inspect(advice_cost_error(88, 200), content="")
  // 87 的成本 = 202×87²×200 = 3.06e8 <= 2.5e9/8 = 3.125e8；88 就超了。
  assert_true(advice_cost_percent(87, 200) <= 12L)
  assert_true(advice_cost_percent(88, 200) >= 12L)
}

///|
test "advice hint: 快速档必须严格快于上限档，否则不写「更快」" {
  // 小配置：上限档与快速档算出同一个值时（都退化成 1），不许出现「更快的一档」。
  let msg = advice_cost_error(50000, 100000)
  assert_false(msg.contains("更快的一档"))
}

///|
test "advice hint: --review-limit 0 时不给「把 --review-limit 降到…」这种建议（老口径）" {
  let msg = advice_cost_error(5000, 0)
  assert_true(msg.contains("把 --days 降到 99 以内"))
  assert_true(msg.contains("只能减 --days"))
  assert_false(msg.contains("把 --review-limit 降到"))
  // 快速档同样只动 --days。
  assert_true(msg.contains("更快的一档"))
  assert_true(msg.contains("--days 35"))
  inspect(advice_cost_error(99, 0), content="")
  inspect(advice_cost_error(35, 0), content="")
}

///|
test "advice hint: 成本百分比封顶在 100，饱和成本不会绕成负数" {
  // 100000/100000 的成本饱和到 Int64.MAX ⇒ 百分比按 100 处理。
  inspect(advice_cost_percent(100000, 100000), content="100")
  inspect(advice_cost_units(100000, 100000), content="9223372036854775807")
  // 常规值：90/200 = 3.27e8 / 2.5e9 = 13%
  inspect(advice_cost_percent(90, 200), content="13")
}
