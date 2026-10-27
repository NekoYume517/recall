// ============================================================================
// RC-7 回归测试（2026-10-27）：成功路径的稳定性下限必须对非正 S 也成立
//
// 公式（fsrs.mbt）：
//   S' = S · (1 + exp(w8)·(11-D)·S^(-w9)·(exp(w10·(1-R))-1)·…)
// 其中的 `S^(-w9)` 在 S=0 时是 +Inf，与后面的项相乘得 NaN；
// S<0 时 pow 直接给 NaN。而收尾的下限判断是
//   `if next < 0.1 { 0.1 } else { next }` —— NaN < 0.1 为 false，
// 于是 NaN 被**原样返回**，下限承诺失效。
//
// 对照：遗忘路径 stability_after_lapse 用了三分支 + `s < 0.1` 兜底，
// 实测 S=-1 时正确返回 0.1。同族函数必须同族语义。
//
// 可达性：`impl Scheduler for Fsrs` 的 review 路径被 step 的
// `is_first || s <= 0.0` 挡在前面，**CLI 不可达**；但这是公开 `pub fn`
// （API.md 3.2 记录为公式入口），且被 validate_fsrs_semantics 调用，
// 库级直接调用（自备权重实验、外部状态修复、测试辅助）会拿到 NaN
// 并向下游扩散：interval_days(NaN, dr) → 1 天，静默把"无记忆"当成
// "刚学完"。
// ============================================================================

///|
test "RC-7: stability_after_success 对 S=0 返回下限而非 NaN" {
  let w = fsrs_default_w()
  let s = stability_after_success(w, 5.0, 0.0, 0.9, 3)
  println("S'(S=0) = " + s.to_string())
  assert_true(!s.is_nan())
  assert_true(s >= 0.1)
  assert_eq(s, 0.1)
}

///|
test "RC-7: stability_after_success 对负 S 返回下限而非 NaN" {
  let w = fsrs_default_w()
  for bad_s in [-0.0, -1.0, -100.0, -1.0e9] {
    let s = stability_after_success(w, 5.0, bad_s, 0.9, 3)
    println("S'(S=" + bad_s.to_string() + ") = " + s.to_string())
    assert_true(!s.is_nan())
    assert_true(s >= 0.1)
  }
}

///|
test "RC-7: 四种评分下的非正 S 都走下限" {
  let w = fsrs_default_w()
  for rating in [1, 2, 3, 4] {
    for bad_s in [0.0, -1.0] {
      let s = stability_after_success(w, 5.0, bad_s, 0.5, rating)
      assert_true(!s.is_nan())
      assert_true(s >= 0.1)
    }
  }
}

///|
test "RC-7: 与遗忘路径的下限语义对齐" {
  // 遗忘路径在 S=-1 时已正确返回 0.1（既有行为）
  let w = fsrs_default_w()
  let lapse = stability_after_lapse(w, 5.0, -1.0, 0.9)
  assert_eq(lapse, 0.1)
  // 成功路径修复后必须给出同一个量级的下限
  let success = stability_after_success(w, 5.0, -1.0, 0.9, 3)
  assert_eq(success, 0.1)
  // 两者都不是 NaN
  assert_true(!lapse.is_nan())
  assert_true(!success.is_nan())
}

///|
test "RC-7: 正常 S 的计算逐位不变（防过度收紧）" {
  let w = fsrs_default_w()
  // 审计与文档里锁定的锚点
  assert_true(
    (stability_after_success(w, 5.0, 3.0, 0.9, 3) - 10.948986752888501).abs() <
    0.000000001,
  )
  // S=0.1（合法下限）仍然按公式推进，不被守卫截成 0.1
  let s_at_floor = stability_after_success(w, 5.0, 0.1, 0.9, 3)
  assert_true(s_at_floor > 0.1)
  assert_true(!s_at_floor.is_nan())
}

///|
test "RC-7: 只夹非正与非有限 S；S=0.1 与极小正数照常走公式" {
  let w = fsrs_default_w()
  // 合法下限 0.1：按公式推进，结果 > 0.1（不被守卫短路）
  let at_floor = stability_after_success(w, 5.0, 0.1, 0.9, 3)
  assert_true(at_floor > 0.1)
  assert_true(!at_floor.is_nan())
  // 极小正数（1e-300）走公式路径：S^(-w9) 的增益抵不过 S 本身之小，
  // 公式自然给出 < 0.1 的中间值，于是被 `next < 0.1` 兜到下限 0.1。
  // 这是公式的结果而非守卫短路——记录边界值防止将来把守卫写宽。
  let tiny = stability_after_success(w, 5.0, 1.0e-300, 0.9, 3)
  println("S'(1e-300) = " + tiny.to_string())
  assert_true(!tiny.is_nan())
  assert_true(tiny >= 0.1)
  // 关键区分：正数进入的是公式分支（不 early-return），
  // 因此把 S 放大一点就能得到 > 0.1 的结果
  let small = stability_after_success(w, 5.0, 0.5, 0.9, 3)
  assert_true(small > 0.1)
  assert_true(small > at_floor)
}

///|
test "RC-7: NaN 输入 S 也走下限（非有限一律拒绝）" {
  let w = fsrs_default_w()
  let s = stability_after_success(w, 5.0, 0.0 / 0.0, 0.9, 3)
  println("S'(NaN) = " + s.to_string())
  assert_true(!s.is_nan())
  assert_eq(s, 0.1)
}
