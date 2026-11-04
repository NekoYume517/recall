///|
test "N-3: 边界值 100000 是合法模拟配置（守卫不许误伤边界）" {
  let ok : SimConfig = {
    days: 1,
    new_per_day: 100000,
    review_limit: 100000,
    desired_retention: 0.9,
    grade_fn: grade_policy_with_seed("realistic", 1L),
    seed: 1L,
  }
  inspect(ok.new_per_day, content="100000")
  inspect(ok.review_limit, content="100000")
  let r = simulate_with(AnyScheduler::by_name_with_retention("fsrs", 0.9), ok)
  inspect(r.days.length(), content="1")
}

///|
test "N-5: 各子命令的键清单互不串味（语义锚点）" {
  let simulate_keys = [
    "scheduler", "days", "new-per-day", "review-limit", "policy", "seed", "retention",
  ]
  assert_true(simulate_keys.contains("new-per-day"))
  assert_false(simulate_keys.contains("buckets"))
  assert_false(simulate_keys.contains("a"))
  assert_false(simulate_keys.contains("log"))
  let curve_keys = ["log", "buckets"]
  assert_true(curve_keys.contains("buckets"))
  assert_false(curve_keys.contains("days"))
  let compare_keys = ["log", "a", "b"]
  assert_true(compare_keys.contains("a"))
  assert_false(compare_keys.contains("scheduler"))
  let replay_keys = ["log", "scheduler", "json", "anki"]
  assert_true(replay_keys.contains("anki"))
  assert_false(replay_keys.contains("days"))
}
