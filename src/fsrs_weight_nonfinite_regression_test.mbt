// ============================================================================
// 非有限权重下的下限守卫（2026-11-12 审计 R-6）
//
// ## 承诺
//
// `API.md` §3.2 关于宽容构造器 `Fsrs::with_params` 写的是：
//
//   「不校验有限性、范围或模型版本。**底层初始稳定性仍会夹到 0.1 天**。
//     需要明确拒绝无效参数请用 checked 版。」
//
// `src/scheduler.mbt` 的注释同样写着「初始稳定性等底层公式仍有数值下限保护」。
// 这个承诺的意义是：**非有限权重不会静默把 NaN 送进 `CardState`**。
//
// ## 实测（修复前）
//
// 同族四个公式对非有限权重的处置不一致：
//
//   坏掉的权重项        路径                        修复前    应有（同族）
//   w[8]                stability_after_success     0.1       ✔ 有守卫
//   w[11]               stability_after_lapse       0.1       ✔ 有守卫
//   w[0..3]             initial_stability           NaN       ✘ 无守卫
//   w[17]/w[18]         step 的短期分支             NaN       ✘ 无守卫
//
// 后果（`review` 的两条必经路径，`is_first` 与「同日重复评分」）：
//
//     Fsrs::with_params(NaN×21) -> review(Good)  ->  stability = NaN, interval = 1
//     再 review(Good, +1h)      ->                  stability = NaN
//
// NaN 一旦进了 `CardState.stability`，`retrievability` 得 0（判成"彻底忘了"），
// 后续每一次 `step` 都从 NaN 出发，「0.1 下限」这条全局不变量到此为止。
// 根因与 RC-7 / N-2 完全同型：`if s < 0.1 { 0.1 } else { s }` 对 NaN 为 false，
// 收尾判断接不住 NaN。
//
// 可达性：宽容构造器**明文接受**非有限权重（这是它与 `with_params_checked`
// 的分工，不是缺陷），因此下游公式必须自己守住下限——正如 RC-7 给
// `stability_after_success` 加守卫时给出的同一条理由。
// ============================================================================

///|
/// 19 项、每一项都是 `fill` 的权重（用来把某一项弄坏）。
fn r6_weights(fill : Double) -> Array[Double] {
  let w : Array[Double] = []
  for i = 0; i < 21; i = i + 1 {
    ignore(i)
    w.push(fill)
  }
  w
}

///|
test "R-6: initial_stability 对 NaN 权重回落到 0.1 下限" {
  let w = fsrs_default_w()
  w[2] = 0.0 / 0.0 // Good 的初始稳定性
  let s = initial_stability(w, 3)
  assert_false(s.is_nan())
  inspect(s, content="0.1")
}

///|
test "R-6: initial_stability 对 +Inf 权重回落到 0.1 下限" {
  let w = fsrs_default_w()
  w[3] = 1.0 / 0.0 // Easy 的初始稳定性
  let s = initial_stability(w, 4)
  assert_false(s.is_nan())
  assert_true(s < 1.0e308)
  inspect(s, content="0.1")
}

///|
test "R-6: initial_stability 对 -Inf 权重回落到 0.1 下限" {
  let w = fsrs_default_w()
  w[0] = -1.0 / 0.0
  inspect(initial_stability(w, 1), content="0.1")
}

///|
test "R-6: 全 NaN 权重下四种评分的初始稳定性都是 0.1" {
  let w = r6_weights(0.0 / 0.0)
  for rating in [1, 2, 3, 4] {
    let s = initial_stability(w, rating)
    assert_false(s.is_nan())
    inspect(s, content="0.1")
  }
}

///|
test "R-6: step 的短期分支对 NaN 权重回落到 0.1 下限" {
  let w = fsrs_default_w()
  w[17] = 0.0 / 0.0 // 同日指数系数
  let (s, _, _) = step(w, 0.9, 5.0, 3.0, 0.5, 3, false)
  assert_false(s.is_nan())
  inspect(s, content="0.1")
}

///|
test "R-6: step 的短期分支对 +Inf 权重回落到 0.1 下限" {
  let w = fsrs_default_w()
  w[18] = 1.0 / 0.0 // 同日评分偏移
  let (s, _, _) = step(w, 0.9, 5.0, 3.0, 0.5, 2, false)
  assert_false(s.is_nan())
  assert_true(s < 1.0e308)
  inspect(s, content="0.1")
}

///|
test "R-6: review 全链路不再把 NaN 写进 CardState" {
  let s = Fsrs::with_params(r6_weights(0.0 / 0.0))
  let c0 = Scheduler::init(s, "c", 0L)
  let c1 = Scheduler::review(s, c0, Good, 0L)
  assert_false(c1.stability.is_nan())
  assert_true(c1.stability >= 0.1)
  assert_false(c1.difficulty.is_nan())
  assert_false(c1.interval_days.is_nan())
  // 同日再复习一次（走短期分支）
  let c2 = Scheduler::review(s, c1, Good, 3600L)
  assert_false(c2.stability.is_nan())
  assert_true(c2.stability >= 0.1)
  // 可提取性仍在 [0,1] 内（NaN 会让它掉到 0）
  let r = Scheduler::retrievability(s, c2, 7200L)
  assert_false(r.is_nan())
  assert_true(r >= 0.0 && r <= 1.0)
}

///|
test "R-6: 合法权重下初始稳定性逐位不变（防过度收紧）" {
  let w = fsrs_default_w()
  inspect(initial_stability(w, 1), content="0.40255")
  inspect(initial_stability(w, 2), content="1.18385")
  inspect(initial_stability(w, 3), content="3.173")
  inspect(initial_stability(w, 4), content="15.69105")
  // 小于 0.1 的**有限**权重仍按既有规则夹到 0.1（不是新加的守卫在起作用）
  let w2 = fsrs_default_w()
  w2[2] = 0.05
  inspect(initial_stability(w2, 3), content="0.1")
  // 恰好 0.1 与更大的有限值原样返回
  w2[2] = 0.1
  inspect(initial_stability(w2, 3), content="0.1")
}

///|
test "R-6: 合法权重下短期分支的值不变（防过度收紧）" {
  let w = fsrs_default_w()
  let (s, _, _) = step(w, 0.9, 5.0, 3.0, 0.5, 3, false)
  // S · exp(w17 · (g - 3 + w18)) = 3 · exp(0.51655 · 0.6621)
  assert_true((s - 4.223313644212624).abs() < 0.000000000001)
}
