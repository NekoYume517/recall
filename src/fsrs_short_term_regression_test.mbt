// FSRS-5 reference: fsrs4anki v5.3.0, next_short_term_stability.
// Formula values are unrounded; the reference UI's display rounding and fuzz
// are deliberately excluded from this inference library.

///|
test "fsrs review regression: same-day Good uses short-term stability" {
  let w = fsrs_default_w()
  let (actual, _, _) = step(w, 0.9, 5.0, 3.0, 0.0, 3, false)
  assert_true((actual - 4.223313644212624).abs() < 0.000000001)
}

///|
test "fsrs review regression: all same-day ratings use w17 and w18" {
  let w = fsrs_default_w()
  for rating in [1, 2, 3, 4] {
    let expected = 3.0 * @math.exp(w[17] * (rating.to_double() - 3.0 + w[18]))
    for elapsed in [0.0, 0.5, 0.999] {
      let (actual, d, iv) = step(w, 0.9, 5.0, 3.0, elapsed, rating, false)
      assert_true((actual - expected).abs() < 0.000000001)
      assert_eq(d, next_difficulty(w, 5.0, rating))
      assert_eq(iv, interval_days(expected, 0.9))
    }
  }
}

///|
test "fsrs review regression: first rating bypasses short-term update" {
  let w = fsrs_default_w()
  let (s, d, _) = step(w, 0.9, 0.0, 0.0, 0.0, 3, true)
  assert_eq(s, w[2])
  assert_eq(d, initial_difficulty(w, 3))
}

///|
test "fsrs review regression: exactly one day uses long-term update" {
  let w = fsrs_default_w()
  let (same_day, _, _) = step(w, 0.9, 5.0, 3.0, 0.999, 3, false)
  let (next_day, _, _) = step(w, 0.9, 5.0, 3.0, 1.0, 3, false)
  assert_true((same_day - next_day).abs() > 0.001)
}
