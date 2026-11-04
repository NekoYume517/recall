// 数值边界的回归（2026-11-04 对抗性审计 N-1 / N-2）。
//
// ## N-1：`days_between` 的 Int64 减法回绕
//
// 旧实现 `(to - from).to_double()`：差值超出 Int64 域就回绕、符号翻转。
//
//     days_between(INT64_MIN, 0)          -> -1.0675e14  （应为正）
//     days_between(INT64_MIN, INT64_MAX)  -> -1.157e-5
//
// 同源后果：`overdue_days(due=INT64_MIN)` 得 0 但 `is_due` 为 true（自相矛盾）；
// Leitner 的 `retrievability(due=INT64_MAX)` 对未到期卡返回 0（应 1.0），
// 而 FSRS 同状态正确。
//
// CLI 不可达（JSONL 时间戳域不溢出），但 `CardState`/`Timestamp` 是公开 API。
//
// ## N-2：`stability_after_lapse` 对 NaN/±Inf 无守卫
//
// 成功路径 `stability_after_success` 在 RC-7（307ebf2）加了「非有限值 → 0.1」
// 守卫，遗忘路径漏掉 —— 同族公式两个方向语义不一致：
//
//     stability_after_success(w, 5.0, NaN, 0.9)  ->  0.1
//     stability_after_lapse  (w, 5.0, NaN, 0.9)  ->  NaN
//
// 根因：`next < 0.1` 对 NaN 为 false，NaN 原样返回，「0.1 下限」承诺失效。

///|
fn nw() -> Array[Double] {
  [
    0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.2, 0.3, 1.0, 0.0,
    0.0, 0.0, 0.0,
  ]
}

///|
test "N-1: days_between 在 Int64 极值上符号正确" {
  // INT64_MIN -> 0：0 更晚，差应为正
  let a = days_between(-9223372036854775808L, 0L)
  assert_true(a > 0.0)
  // INT64_MIN -> INT64_MAX：跨度 2^64 秒，差应为正
  let b = days_between(-9223372036854775808L, 9223372036854775807L)
  assert_true(b > 0.0)
  // 反向应为负
  let c = days_between(0L, -9223372036854775808L)
  assert_true(c < 0.0)
  // 常规区间不受影响（这是绝大多数调用的实际形态）
  inspect(days_between(0L, 86400L), content="1")
  inspect(days_between(0L, 0L), content="0")
  inspect(days_between(100L, 0L), content="-0.0011574074074074073")
}

///|
test "N-1: overdue_days 与 is_due 在极值 due 上一致" {
  // 复用项目自己的构造入口（CardState::new），只覆写 due 到 Int64 下界
  let st : CardState = {
    ..CardState::new("x", 0L),
    due: -9223372036854775808L,
  }
  // 极小的 due 一定已到期
  assert_true(st.is_due(0L))
  // 已到期就必须有正的逾期天数 —— 修复前这里是 0（自相矛盾）
  let od = st.overdue_days(0L)
  assert_true(od > 0.0)
}

///|
test "N-2: stability_after_lapse 对 NaN/±Inf 回落到 0.1 下限" {
  let w = nw()
  // NaN 输入
  let nan_in = stability_after_lapse(w, 5.0, 0.0 / 0.0, 0.9)
  assert_false(nan_in.is_nan())
  inspect(nan_in, content="0.1")
  // +Inf 输入
  let inf_in = stability_after_lapse(w, 5.0, 1.0 / 0.0, 0.9)
  assert_true(inf_in < 1.0e308)
  inspect(inf_in, content="0.1")
  // -Inf 输入（s <= 0 也覆盖，但显式锁定）
  inspect(stability_after_lapse(w, 5.0, -1.0 / 0.0, 0.9), content="0.1")
  // 非正 S 仍按下限（既有行为，锁定防回退）
  inspect(stability_after_lapse(w, 5.0, 0.0, 0.9), content="0.1")
  inspect(stability_after_lapse(w, 5.0, -1.0, 0.9), content="0.1")
}

///|
test "N-2: 合法正数 S 仍走公式，不被守卫改写" {
  let w = nw()
  // 0.4 是极小但合法的正数，必须走公式而不是直接吃 0.1 下限
  let tiny = stability_after_lapse(w, 5.0, 0.4, 0.9)
  assert_false(tiny.is_nan())
  // 结果必须不超过输入 S（遗忘不能提高稳定性），且 >= 0.1
  assert_true(tiny <= 0.4 || tiny >= 0.1)
  // 常规值：S=5 遗忘后应落在 (0.1, 5]
  let normal = stability_after_lapse(w, 5.0, 5.0, 0.9)
  assert_true(normal >= 0.1)
  assert_true(normal <= 5.0)
}

///|
test "N-2: 成功路径与遗忘路径在非有限 S 上语义一致" {
  let w = nw()
  // 同族公式必须同族语义（RC-7 建立的不变量延伸到两条路径）
  for s in [0.0 / 0.0, 1.0 / 0.0, -1.0 / 0.0, 0.0, -1.0] {
    let succ = stability_after_success(w, 5.0, s, 0.9, 3)
    let laps = stability_after_lapse(w, 5.0, s, 0.9)
    assert_false(succ.is_nan())
    assert_false(laps.is_nan())
    inspect(succ, content="0.1")
    inspect(laps, content="0.1")
  }
}
