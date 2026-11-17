///|
/// 审计回归（第十二轮，P3）：FSRS 数值面的**同族守卫**四处补漏。
///
/// 这一组的共同形态是 DISCIPLINE §5.1 那条——
/// 「同一份语义要在两个地方各写一遍的结构，就是漏一处的温床」：
///
/// | 位置 | 修复前 | 同族另一处 |
/// |---|---|---|
/// | `initial_difficulty` 的 rating | **不夹**（g=0 与 g=1 给出不同 D） | `initial_stability` 夹到 1..4 |
/// | `clamp_difficulty(NaN)` | `5.0`（一个看似合理的中间值） | S→0.1 / EF→1.3 / R→0（都落端点） |
/// | `interval_days` 的 `dr` | 比较式漏 NaN ⇒ 兜成 **1 天** | `clamp_retention(NaN)` = 0.9（权威） |
/// | `stability_after_lapse` 的 `short_cap` | NaN 时**静默失效**（上限被跳过） | 同函数对 `s` / `next` 都有守卫 |

///|
test "rating 夹取：initial_difficulty 与 initial_stability 同口径" {
  let w = fsrs_default_w()
  // 定义域 1..4 之外必须夹到端点——两个入口行为必须一致。
  assert_true(initial_stability(w, 0) == initial_stability(w, 1))
  assert_true(initial_difficulty(w, 0) == initial_difficulty(w, 1))
  assert_true(initial_stability(w, 7) == initial_stability(w, 4))
  assert_true(initial_difficulty(w, 7) == initial_difficulty(w, 4))
  // 域内 1..4 逐位不变：D₀(1) = w[4] = 7.1949、D₀(4) = 3.2245…
  assert_true(initial_difficulty(w, 1) == w[4])
  assert_true(initial_difficulty(w, 4) < initial_difficulty(w, 1))
}

///|
test "非有限兜底口径：D 与 S / EF / R 同族（都落端点，不换中间值）" {
  let w = fsrs_default_w()
  // S 的下限 0.1（RC-7 / N-2 既有行为）
  assert_true(stability_after_success(w, 5.0, 0.0 / 0.0, 0.9, 3) == 0.1)
  // EF 的下限 1.3（D2 既有行为）
  assert_true(sm2_next_ease(0.0 / 0.0, Good) == 1.3)
  // R 的下限 0（既有行为）
  assert_true(clamp_retrievability(0.0 / 0.0) == 0.0)
  // D 的下限 1.0（本轮修复；修复前是 5.0）
  assert_true(next_difficulty(w, 0.0 / 0.0, 3) == 1.0)
  // 权重非有限时 D₀ 同样落到下限，而不是 5.0。
  let wn = fsrs_default_w()
  wn[4] = 0.0 / 0.0
  assert_true(initial_difficulty(wn, 3) == 1.0)
}

///|
test "interval_days 的 dr：NaN 走 clamp_retention 的权威兜底（0.9），不是 1 天" {
  let w = fsrs_default_w()
  // 权威：clamp_retention(NaN) = 0.9 ⇒ interval_days(S, NaN) 必须等于 (S, 0.9)。
  inspect(clamp_retention(0.0 / 0.0), content="0.9")
  assert_true(interval_days(100.0, 0.0 / 0.0) == 100.0)
  assert_true(interval_days(100.0, 0.9) == 100.0)
  assert_true(interval_days(7.0, 0.0 / 0.0) == 7.0)
  // 双向：区间内的越界值夹到边界；区间外的无效值回退 0.9（三段语义）。
  assert_true(interval_days(100.0, 0.4) == interval_days(100.0, 0.5))
  assert_true(interval_days(100.0, 0.995) == interval_days(100.0, 0.99))
  assert_true(interval_days(100.0, 0.0) == interval_days(100.0, 0.9))
  assert_true(interval_days(100.0, 1.0) == interval_days(100.0, 0.9))
  // 定义性恒等式不受影响：dr=0.9 时 I(S) = S（S ∈ [1, 36500] 内未取整相等）。
  for s in [1.0, 3.0, 21.37, 36500.0] {
    assert_true(interval_days(s, 0.9) == @math.round(s))
  }
  let _ = w
}

///|
test "stability_after_lapse 的 short_cap：w17/w18 非有限时上限仍然生效" {
  let s = 22.75
  let d = 3.0
  let r = 0.05
  // 默认权重下 raw ≈ 23.08 > cap = s/exp(w17·w18) ≈ 16.16（既有用例锁的
  // py-fsrs 值），这里只关心「上限永远存在」。
  let w_ok = fsrs_default_w()
  assert_true(stability_after_lapse(w_ok, d, s, r) <= s)
  // w17 = NaN：修复前 cap 变 NaN ⇒ `next > NaN` 恒假 ⇒ 上限被跳过，
  // 返回 raw ≈ 23.08（> s）。修复后兜底到 FSRS-4.5 的上限 s。
  let w_nan = fsrs_default_w()
  w_nan[17] = 0.0 / 0.0
  let got = stability_after_lapse(w_nan, d, s, r)
  assert_true(got <= s)
  assert_true(got == s)
  // 下限也不受影响。
  assert_true(stability_after_lapse(w_nan, d, 0.0, r) == 0.1)
}
