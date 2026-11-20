// 断言补强（2026-11-21 审计，#7）：SM-2 在 `reps = Int32.MAX` 时
// `sm2_next_interval` 里的 `let n = repetitions + 1` 先回绕成 `Int32.MIN`，
// 才进入 `n == 1 / n == 2` 的判定。
//
// 现状行为恰好可接受：回绕值不命中 1/2，于是走几何分支
// `round(prev × ease)`，与「饱和计数继续按几何增长」的直觉一致；本机实测
// 不 panic（MoonBit 的 Int 运算回绕不陷入）。
//
// 但这是上一轮「计数饱和」修复（scheduler_counter_overflow_regression_test）
// 之后**新可达**的局部回绕：那条测试只断言 `reps/lapses >= 0`，没有钉住
// 「MAX 时到底走哪个分支」。若以后有人把判定改成 `n <= 2` 或先夹后加，
// 分支会静默换档（例如再次变成「首次复习」的 `prev × 1`），行为改变却不
// 会有测试变红。这里用具体数值把分支选择钉死。

///|
test "SM-2 reps 饱和: n = reps+1 回绕后仍走几何分支，区间有限且计数饱和" {
  let s = Sm2::new()
  let state : CardState = {
    card_id: "c",
    stability: 3.0,
    difficulty: 2.5,
    reps: 2147483647,
    lapses: 7,
    last_review: 0L,
    due: 259200L,
    interval_days: 3.0,
    phase: Phase::Review,
  }
  let next = s.review(state, Grade::Good, 86400L)
  // 几何分支：round(3.0 × 2.5) = 8 天（不是「首次」的 prev×1 = 3）。
  assert_eq(next.interval_days, 8.0)
  assert_eq(next.due, 86400L + 8L * 86400L)
  // 计数在 MAX 饱和，不因 +1 回绕变成负数。
  assert_eq(next.reps, 2147483647)
  assert_true(next.lapses >= 0)
  // EF：Good 的 SM-2 增量是 0（q=4 → 0.1 − 1×(0.08+0.02) = 0），保持 2.5。
  assert_true(approx_default(next.difficulty, 2.5))
}
