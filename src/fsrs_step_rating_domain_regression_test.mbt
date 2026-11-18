///|
/// 2026-11-19 对抗性审查：FSRS `step` 是 rating 定义域夹取的漏网入口。
///
/// `initial_stability` / `initial_difficulty` / `next_difficulty` /
/// `success_chain` 已统一把 rating 夹到 1..4，但 `step` 的非首次分支仍直接
/// 使用原始形参：rating=0 不会走 Again 的遗忘路径，rating=5 也拿不到 Easy
/// 奖励；同日公式同样使用域外指数。于是同一次状态推进内部同时出现两种
/// rating 口径（D 被 next_difficulty 夹取，S 却不夹）。
fn assert_step_rating_clamped(elapsed : Double, is_first : Bool) -> Unit raise {
  let w = fsrs_default_w()
  let low = step(w, 0.9, 5.0, 10.0, elapsed, 0, is_first)
  let again = step(w, 0.9, 5.0, 10.0, elapsed, 1, is_first)
  let high = step(w, 0.9, 5.0, 10.0, elapsed, 5, is_first)
  let easy = step(w, 0.9, 5.0, 10.0, elapsed, 4, is_first)
  assert_true(low.0 == again.0)
  assert_true(low.1 == again.1)
  assert_true(low.2 == again.2)
  assert_true(high.0 == easy.0)
  assert_true(high.1 == easy.1)
  assert_true(high.2 == easy.2)
}

///|
test "step: 越界 rating 在首次/同日/长期路径都按最近端点处理" {
  for first in [true, false] {
    assert_step_rating_clamped(0.0, first)
  }
  assert_step_rating_clamped(0.5, false)
  assert_step_rating_clamped(1.0, false)
  assert_step_rating_clamped(30.0, false)
}

///|
test "step: 域内 rating 的状态推进保持原样" {
  let w = fsrs_default_w()
  let got = step(w, 0.9, 5.0, 10.0, 3.0, 3, false)
  let s = stability_after_success(w, 5.0, 10.0, forgetting_curve(3.0, 10.0), 3)
  assert_true(got.0 == s)
  assert_true(got.1 == next_difficulty(w, 5.0, 3))
  assert_true(got.2 == interval_days(s, 0.9))
}
