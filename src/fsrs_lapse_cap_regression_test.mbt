// FSRS-5 的遗忘上限：`S_f = min(raw, S / exp(w17·w18))`，不是 `min(raw, S)`。
//
// 参考实现：py-fsrs 5.1.3 `Scheduler._next_forget_stability`（与 4.1.2 的差别
// 正在这里 —— 4.x 用 `min(raw, S)`，5.x 用 `min(raw, S / exp(w17·w18))`）。
// 本文件的期望值全部由 py-fsrs 5.1.3 逐点算出的真实输出抄来，不是在 MoonBit
// 里重跑一遍实现（照抄同一个技巧的「独立实现」不算独立）。

///|
/// 长间隔遗忘不会把极小的稳定性抬高。
test "fsrs review regression: a long lapse cannot improve tiny stability" {
  let w = fsrs_default_w()
  let (s, _, iv) = step(w, 0.9, 5.0, 0.1, 365.0, 1, false)
  assert_eq(s, 0.1)
  assert_eq(iv, 1.0)
}

///|
/// 遗忘后的稳定性必须落在 `[0.1, S / exp(w17·w18)]` 区间里 —— 上限是
/// **短期上限**，不是旧的裸 `S`（R-1，2026-11-11 审计）。
///
/// 旧断言写的是 `new_s <= old_s`，在这条 bug 存在时也恒成立（cap = S 比
/// 短期上限更松），因此它锁不住任何东西。
test "fsrs review regression: lapse stability stays between floor and the short-term cap" {
  let w = fsrs_default_w()
  let cap_ratio = @math.exp(w[17] * w[18])
  for old_s in [0.1, 0.2, 0.5, 1.0, 3.0, 20.0] {
    for elapsed in [1.0, 365.0, 36500.0] {
      let r = forgetting_curve(elapsed, old_s)
      let new_s = stability_after_lapse(w, 5.0, old_s, r)
      assert_true(new_s >= 0.1)
      assert_true(new_s <= old_s)
      // 直接锁上限：`min(raw, S/exp(w17·w18))` 之后不许超过上限，
      // 且下限 0.1 仍然有效（S 极小时 cap 会低于 0.1）。
      let cap = old_s / cap_ratio
      assert_true(new_s <= cap || new_s == 0.1)
    }
  }
}

///|
/// 逐点对照 py-fsrs 5.1.3 的真实输出（`Scheduler._next_forget_stability`）。
///
/// 选点覆盖三条区段：
/// - `(5, 3, 0.5)` / `(7, 3, 0.05)`：**短期上限起作用**，结果与 D、R 无关，
///   恒等于 `S / exp(w17·w18) = 3/1.4077712… = 2.1310280879406296`
///   （旧实现给 2.5648860200305696 —— 未封顶的长项，+20.4%）
/// - `(10, 0.5, 0.9)` / `(1, 3, 0.9)`：**长项起作用**（raw < cap）
/// - `(3, 22.75, 0.05)`：审计报告里偏差最大的一点（旧实现 22.75，官方 16.16）
test "fsrs review regression: lapse stability matches py-fsrs 5.1.3 point by point" {
  let w = fsrs_default_w()
  // (D, S, R, py-fsrs 5.1.3 _next_forget_stability)
  let cases : Array[(Double, Double, Double, Double)] = [
    (5.0, 3.0, 0.5, 2.1310280879406296),
    (7.0, 3.0, 0.05, 2.1310280879406296),
    (1.0, 0.5, 0.05, 0.35517134799010497),
    (10.0, 0.5, 0.9, 0.24094122666609735),
    (5.0, 20.0, 0.9, 2.9825488150843076),
    (10.0, 22.75, 0.9, 2.9362281462831277),
    (3.0, 22.75, 0.05, 16.160296333549773),
    (1.0, 3.0, 0.9, 1.2349521339182399),
  ]
  for c in cases {
    let (d, s, r, want) = c
    let got = stability_after_lapse(w, d, s, r)
    assert_true(
      (got - want).abs() < 0.000000001,
      msg="D=\{d} S=\{s} R=\{r}: got \{got}, py-fsrs 5.1.3 gives \{want}",
    )
  }
}

///|
/// 窄口径锚点：默认权重、`(D,S,R) = (5,3,0.5)` 的结果必须等于官方值，
/// 且校验器与语义检查都仍然通过。
test "fsrs review regression: lapse cap preserves ordinary reference values" {
  let w = fsrs_default_w()
  let actual = stability_after_lapse(w, 5.0, 3.0, 0.5)
  assert_true((actual - 2.1310280879406296).abs() < 0.000000001)
  assert_true(validate_fsrs_semantics(w) is Valid)
  assert_true(validate_fsrs_reference() is Valid)
}
