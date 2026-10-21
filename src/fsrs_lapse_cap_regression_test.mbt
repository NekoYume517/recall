// FSRS-5 v5.3.0 next_forget_stability caps the result at old stability.
// Independent default-weight calculation for D=5, S=0.1, elapsed=365:
// R=0.034155905181480074, raw=0.41642906314827216, min(raw,S)=0.1.

///|
test "fsrs review regression: a long lapse cannot improve tiny stability" {
  let w = fsrs_default_w()
  let (s, _, iv) = step(w, 0.9, 5.0, 0.1, 365.0, 1, false)
  assert_eq(s, 0.1)
  assert_eq(iv, 1.0)
}

///|
test "fsrs review regression: lapse stability stays between floor and old stability" {
  let w = fsrs_default_w()
  for old_s in [0.1, 0.2, 0.5, 1.0, 3.0, 20.0] {
    for elapsed in [1.0, 365.0, 36500.0] {
      let r = forgetting_curve(elapsed, old_s)
      let new_s = stability_after_lapse(w, 5.0, old_s, r)
      assert_true(new_s >= 0.1)
      assert_true(new_s <= old_s)
    }
  }
}

///|
test "fsrs review regression: lapse cap preserves ordinary reference values" {
  let w = fsrs_default_w()
  let actual = stability_after_lapse(w, 5.0, 3.0, 0.5)
  assert_true((actual - 2.5648860200305696).abs() < 0.000000001)
  assert_true(validate_fsrs_semantics(w) is Valid)
  assert_true(validate_fsrs_reference() is Valid)
}
