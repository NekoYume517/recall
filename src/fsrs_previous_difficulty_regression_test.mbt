// Unrounded FSRS-5 formulas, fsrs4anki v5.3.0 review branch.
// The reference passes last_d to both stability updates.

///|
test "fsrs review regression: long-term Easy uses previous difficulty" {
  let w = fsrs_default_w()
  let (s, _, _) = step(w, 0.9, 5.0, 3.0, 3.0, 4, false)
  assert_true((s - 26.765880593786036).abs() < 0.000000001)
}

///|
test "fsrs review regression: long-term Again uses previous difficulty" {
  let w = fsrs_default_w()
  let (s, d, _) = step(w, 0.9, 5.0, 20.0, 10.0, 1, false)
  let expected = stability_after_lapse(
    w,
    5.0,
    20.0,
    forgetting_curve(10.0, 20.0),
  )
  assert_true((s - expected).abs() < 0.000000001)
  assert_eq(d, next_difficulty(w, 5.0, 1))
}
