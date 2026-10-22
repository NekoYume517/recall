///|
test "Fsrs constructors own their weight arrays" {
  let loose_weights = fsrs_default_w()
  let loose = Fsrs::with_params(loose_weights)
  loose_weights.clear()
  assert_eq(loose.weights().length(), 21)
}

///|
test "Fsrs checked constructor owns its weight array" {
  let checked_weights = fsrs_default_w()
  match Fsrs::with_params_checked(checked_weights) {
    Ok(checked) => {
      checked_weights.clear()
      assert_eq(checked.weights().length(), 21)
    }
    Err(msg) => fail(msg)
  }
}

///|
test "Fsrs weight snapshots cannot mutate the scheduler" {
  let sched = Fsrs::new()
  let snapshot = sched.weights()
  snapshot[2] = 99.0
  snapshot.clear()
  assert_eq(sched.weights().length(), 21)
  let result = sched.review(sched.init("card", 0L), Good, 0L)
  assert_eq(result.stability, 3.173)
}
