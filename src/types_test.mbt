// types.mbt 白盒测试
//
// 覆盖：Grade 的整数往返与夹取、is_recalled 判定、Timestamp 别名、
// CardState 构造/到期判定、天数换算。
//
// 注意（MOONBIT-GUIDE 第 10 节）：
// - `derive(Debug)` 不提供 `Show`，所以 inspect 不能直接打印枚举/结构体；
//   枚举用 `==` 比较后 inspect Bool，或用 `label()` 换成 String。
// - 浮点不要用 inspect 精确比字符串，先绑变量再用容差。
// - 共享辅助函数 `approx` 在 test_helpers_test.mbt。

///|
test "grade to_int 是展示用刻度" {
  inspect(Grade::to_int(Grade::Again), content="0")
  inspect(Grade::to_int(Grade::Hard), content="2")
  inspect(Grade::to_int(Grade::Good), content="3")
  inspect(Grade::to_int(Grade::Easy), content="5")
}

///|
test "grade from_int 映射 0..5" {
  inspect(Grade::label(Grade::from_int(0)), content="again")
  inspect(Grade::label(Grade::from_int(1)), content="hard")
  inspect(Grade::label(Grade::from_int(2)), content="hard")
  inspect(Grade::label(Grade::from_int(3)), content="good")
  inspect(Grade::label(Grade::from_int(4)), content="easy")
  inspect(Grade::label(Grade::from_int(5)), content="easy")
}

///|
test "grade from_int 越界夹到两端" {
  inspect(Grade::label(Grade::from_int(-100)), content="again")
  inspect(Grade::label(Grade::from_int(-1)), content="again")
  inspect(Grade::label(Grade::from_int(6)), content="easy")
  inspect(Grade::label(Grade::from_int(999)), content="easy")
}

///|
test "grade 整数往返（只对 0/2/3/5 恒等）" {
  // Hard 覆盖 1..2、Easy 覆盖 4..5，所以只有这四档往返恒等
  inspect(Grade::to_int(Grade::from_int(0)), content="0")
  inspect(Grade::to_int(Grade::from_int(2)), content="2")
  inspect(Grade::to_int(Grade::from_int(3)), content="3")
  inspect(Grade::to_int(Grade::from_int(5)), content="5")
}

///|
test "is_recalled 是统一判定：只有 Again 算失败" {
  inspect(is_recalled(Grade::Again), content="false")
  // Hard 算成功回忆（q=3，SM-2 也判答对）
  inspect(is_recalled(Grade::Hard), content="true")
  inspect(is_recalled(Grade::Good), content="true")
  inspect(is_recalled(Grade::Easy), content="true")
}

///|
test "is_pass 已修正为 is_recalled 的别名" {
  // 历史上 is_pass 实现成 to_int >= 3（把 Hard 判失败），已修正
  inspect(Grade::is_pass(Grade::Again), content="false")
  inspect(Grade::is_pass(Grade::Hard), content="true")
  inspect(Grade::is_pass(Grade::Good), content="true")
  inspect(Grade::is_pass(Grade::Easy), content="true")
  // 与 is_recalled 完全等价
  for g in [Grade::Again, Grade::Hard, Grade::Good, Grade::Easy] {
    inspect(Grade::is_pass(g) == is_recalled(g), content="true")
  }
}

///|
test "grade label 往返" {
  inspect(Grade::label(Grade::Again), content="again")
  inspect(Grade::label(Grade::Hard), content="hard")
  inspect(Grade::label(Grade::Good), content="good")
  inspect(Grade::label(Grade::Easy), content="easy")
  match Grade::from_label("good") {
    Some(g) => inspect(Grade::to_int(g), content="3")
    None => inspect("missing", content="good")
  }
  match Grade::from_label("nope") {
    Some(_) => inspect("unexpected", content="None")
    None => inspect("none", content="none")
  }
}

///|
test "grade derive(Eq) 可用" {
  inspect(Grade::Good == Grade::Good, content="true")
  inspect(Grade::Good == Grade::Easy, content="false")
  inspect(Grade::Again == Grade::Hard, content="false")
}

///|
test "timestamp 是 Int64 别名" {
  let t : Timestamp = 1700000000L
  inspect(t.to_string(), content="1700000000")
  let later = t + 86400L
  inspect(later.to_string(), content="1700086400")
  inspect(later > t, content="true")
}

///|
test "days_between 基本换算" {
  let a : Timestamp = 0L
  let b : Timestamp = 86400L
  let d = days_between(a, b)
  assert_true(approx(d, 1.0, 0.000000001))
  let d3 = days_between(a, 259200L)
  assert_true(approx(d3, 3.0, 0.000000001))
}

///|
test "days_between 可以为负" {
  let d = days_between(86400L, 0L)
  assert_true(approx(d, -1.0, 0.000000001))
}

///|
test "seconds_per_day 常量" {
  let s = seconds_per_day()
  assert_true(approx(s, 86400.0, 0.000000001))
}

///|
test "add_days 四舍五入到整秒" {
  let now : Timestamp = 1700000000L
  inspect(add_days(now, 1.0).to_string(), content="1700086400")
  inspect(add_days(now, 0.0).to_string(), content="1700000000")
  inspect(add_days(now, 0.5).to_string(), content="1700043200")
  let third = add_days(now, 1.0 / 3.0)
  inspect(third.to_string(), content="1700028800")
}

///|
test "card state new 是白板" {
  let st = CardState::new("c1", 1700000000L)
  inspect(st.card_id, content="c1")
  assert_true(approx(st.stability, 0.0, 0.000000001))
  assert_true(approx(st.difficulty, 0.0, 0.000000001))
  inspect(st.reps, content="0")
  inspect(st.lapses, content="0")
  inspect(st.last_review.to_string(), content="1700000000")
  inspect(st.due.to_string(), content="1700000000")
  assert_true(approx(st.interval_days, 0.0, 0.000000001))
  inspect(Phase::label(st.phase), content="新卡")
}

///|
test "card state is_new" {
  let st = CardState::new("c1", 100L)
  inspect(st.is_new(), content="true")
  let reviewed = { ..st, reps: 1, }
  inspect(reviewed.is_new(), content="false")
}

///|
test "card state is_due 边界" {
  let st = { ..CardState::new("c1", 0L), due: 1000L, }
  inspect(st.is_due(1000L), content="true")
  inspect(st.is_due(1001L), content="true")
  inspect(st.is_due(999L), content="false")
}

///|
test "card state overdue_days" {
  let st = { ..CardState::new("c1", 0L), due: 0L, }
  let early = st.overdue_days(-86400L)
  assert_true(approx(early, 0.0, 0.000000001))
  let on_time = st.overdue_days(0L)
  assert_true(approx(on_time, 0.0, 0.000000001))
  let late = st.overdue_days(172800L)
  assert_true(approx(late, 2.0, 0.000000001))
}

///|
test "card state equal 逐字段" {
  let a = CardState::new("c1", 100L)
  let b = CardState::new("c1", 100L)
  inspect(CardState::equal(a, b), content="true")
  let c = { ..a, reps: 1, }
  inspect(CardState::equal(a, c), content="false")
  let d = { ..a, card_id: "c2", }
  inspect(CardState::equal(a, d), content="false")
  let e = { ..a, phase: Phase::Review, }
  inspect(CardState::equal(a, e), content="false")
}

///|
test "phase label" {
  inspect(Phase::label(Phase::New), content="新卡")
  inspect(Phase::label(Phase::Learning), content="学习中")
  inspect(Phase::label(Phase::Review), content="复习")
  inspect(Phase::label(Phase::Relearning), content="重学")
}

///|
test "phase derive(Eq)" {
  inspect(Phase::New == Phase::New, content="true")
  inspect(Phase::New == Phase::Review, content="false")
  inspect(Phase::Relearning == Phase::Relearning, content="true")
}
