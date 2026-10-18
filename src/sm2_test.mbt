// sm2.mbt 白盒测试
//
// 核心：**手算表格测试**。四组序列的每一次 interval / EF 都写死，
// 任何一处偏离公式都会立刻被抓到。
//
// 手算依据（API.md 3.1，唯一权威 q 映射）：
//   Again→2, Hard→3, Good→4, Easy→5
//   答错判定：q < 3（只有 Again 算答错）
//   EF 增量：0.1 - (5-q) * (0.08 + (5-q) * 0.02)
//     q=5 → +0.10   q=4 → 0.00   q=3 → -0.14   q=2 → -0.32
//   顺序：先用**上一次的 EF** 算间隔，再更新 EF
//
// 注意（MOONBIT_GUIDE 第 10 节）：浮点不要用 inspect 精确比字符串，
// 先绑变量再用容差；也不支持 1e-9 这种科学计数法。
// 共享辅助函数 `approx` 在 test_helpers_test.mbt。

///|
/// 按顺序回放一串评分，返回每次复习后的 (interval_days, ef)。
/// 时间戳每次前进「当前间隔天数」，模拟理想复习节奏。
fn play(seq : Array[Grade]) -> Array[(Double, Double)] {
  let sched = Sm2::new()
  let mut state = sched.init("c1", 0L)
  let out : Array[(Double, Double)] = []
  let mut now : Timestamp = 0L
  for g in seq {
    state = sched.review(state, g, now)
    out.push((state.interval_days, state.difficulty))
    now = state.due
  }
  out
}

// ─────────────────────────────────────────────────────────────────
// 第 1 组：Good × 5 → 间隔 1, 6, 15, 38, 95；EF 恒为 2.5
//
// q=4 时 delta = 0.1 - 1*(0.08 + 1*0.02) = 0.1 - 0.1 = 0，EF 不动。
// 所以每次都用 2.5 乘：
//   第 3 次 round(6   * 2.5) = round(15.0)  = 15
//   第 4 次 round(15  * 2.5) = round(37.5)  = 38   （half-up）
//   第 5 次 round(38  * 2.5) = round(95.0)  = 95
// ─────────────────────────────────────────────────────────────────

///|
test "SM-2 表 1: Good x5 间隔与 EF" {
  let r = play([Grade::Good, Grade::Good, Grade::Good, Grade::Good, Grade::Good])
  inspect(r.length(), content="5")
  // 每次的 interval
  assert_true(approx(r[0].0, 1.0, 0.000000001))
  assert_true(approx(r[1].0, 6.0, 0.000000001))
  assert_true(approx(r[2].0, 15.0, 0.000000001))
  assert_true(approx(r[3].0, 38.0, 0.000000001))
  assert_true(approx(r[4].0, 95.0, 0.000000001))
  // EF 全程 2.5
  assert_true(approx(r[0].1, 2.5, 0.000000001))
  assert_true(approx(r[1].1, 2.5, 0.000000001))
  assert_true(approx(r[2].1, 2.5, 0.000000001))
  assert_true(approx(r[3].1, 2.5, 0.000000001))
  assert_true(approx(r[4].1, 2.5, 0.000000001))
}

// ─────────────────────────────────────────────────────────────────
// 第 2 组：Easy × 3 → 间隔 1, 6, 16；EF 2.6, 2.7, 2.8
//
// q=5 时 delta = +0.1，每次 EF+0.1。
//   第 1 次：interval=1，EF 2.5→2.6
//   第 2 次：interval=6，EF 2.6→2.7
//   第 3 次：round(6 * 2.7)=round(16.2)=16，EF 2.7→2.8
// ─────────────────────────────────────────────────────────────────

///|
test "SM-2 表 2: Easy x3 间隔与 EF" {
  let r = play([Grade::Easy, Grade::Easy, Grade::Easy])
  inspect(r.length(), content="3")
  assert_true(approx(r[0].0, 1.0, 0.000000001))
  assert_true(approx(r[1].0, 6.0, 0.000000001))
  assert_true(approx(r[2].0, 16.0, 0.000000001))
  assert_true(approx(r[0].1, 2.6, 0.000000001))
  assert_true(approx(r[1].1, 2.7, 0.000000001))
  assert_true(approx(r[2].1, 2.8, 0.000000001))
}

// ─────────────────────────────────────────────────────────────────
// 第 3 组：Hard × 3 → 间隔 1, 6, 13；EF 2.36, 2.22, 2.08
//
// q=3 时 delta = 0.1 - 2*(0.08 + 2*0.02) = 0.1 - 0.24 = -0.14
//   第 1 次：interval=1，EF 2.5→2.36
//   第 2 次：interval=6，EF 2.36→2.22
//   第 3 次：用上一次 EF=2.22 → round(6 * 2.22)=round(13.32)=13，EF 2.22→2.08
//
// ⚠️ 关键：第 3 次用的是 2.22（更新前），不是 2.08。若顺序写反会得到
//    round(6*2.08)=12，本测试就会失败——这正是要守的那个坑。
// ─────────────────────────────────────────────────────────────────

///|
test "SM-2 表 3: Hard x3 间隔与 EF（验证用旧 EF 算间隔）" {
  let r = play([Grade::Hard, Grade::Hard, Grade::Hard])
  inspect(r.length(), content="3")
  assert_true(approx(r[0].0, 1.0, 0.000000001))
  assert_true(approx(r[1].0, 6.0, 0.000000001))
  assert_true(approx(r[2].0, 13.0, 0.000000001))
  assert_true(approx(r[0].1, 2.36, 0.000000001))
  assert_true(approx(r[1].1, 2.22, 0.000000001))
  assert_true(approx(r[2].1, 2.08, 0.000000001))
}

// ─────────────────────────────────────────────────────────────────
// 第 4 组：Good, Good, Again, Good → 间隔 1, 6, 1, 1；EF 2.5, 2.5, 2.18, 2.18
//
//   第 1 次 Good：reps=1，interval=1，EF 2.5（delta 0）
//   第 2 次 Good：reps=2，interval=6，EF 2.5
//   第 3 次 Again：q=2 < 3 → reps=0，interval=1；
//                 EF delta = 0.1 - 3*(0.08+3*0.02) = -0.32 → 2.18
//   第 4 次 Good：reps=1 → interval=1（reps 归零后重新从 1 开始）；
//                 delta 0 → EF 仍 2.18
// ─────────────────────────────────────────────────────────────────

///|
test "SM-2 表 4: Good,Good,Again,Good 间隔与 EF" {
  let r = play([Grade::Good, Grade::Good, Grade::Again, Grade::Good])
  inspect(r.length(), content="4")
  assert_true(approx(r[0].0, 1.0, 0.000000001))
  assert_true(approx(r[1].0, 6.0, 0.000000001))
  assert_true(approx(r[2].0, 1.0, 0.000000001))
  assert_true(approx(r[3].0, 1.0, 0.000000001))
  assert_true(approx(r[0].1, 2.5, 0.000000001))
  assert_true(approx(r[1].1, 2.5, 0.000000001))
  // 这一行是 lead 之前写错的地方：q=2 → 2.18，不是 1.7
  assert_true(approx(r[2].1, 2.18, 0.000000001))
  assert_true(approx(r[3].1, 2.18, 0.000000001))
}

///|
test "SM-2 四组表总校验（一次性打印手算值）" {
  // 把四组的最终间隔序列拼成字符串，与手算表逐字比对
  let sb = StringBuilder()
  let cases : Array[Array[Grade]] = [
    [Grade::Good, Grade::Good, Grade::Good, Grade::Good, Grade::Good],
    [Grade::Easy, Grade::Easy, Grade::Easy],
    [Grade::Hard, Grade::Hard, Grade::Hard],
    [Grade::Good, Grade::Good, Grade::Again, Grade::Good],
  ]
  for seq in cases {
    let r = play(seq)
    for i, pair in r {
      if i > 0 {
        sb.write_char(',')
      }
      sb.write_object(pair.0.to_int())
    }
    sb.write_char('\n')
  }
  inspect(sb.to_string(), content="1,6,15,38,95\n1,6,16\n1,6,13\n1,6,1,1\n")
}

// ─────────────────────────────────────────────────────────────────
// q 映射与 EF 公式的单元测试
// ─────────────────────────────────────────────────────────────────

///|
test "sm2_quality 映射是 2/3/4/5（不是 to_int 的 0/2/3/5）" {
  inspect(sm2_quality(Grade::Again), content="2")
  inspect(sm2_quality(Grade::Hard), content="3")
  inspect(sm2_quality(Grade::Good), content="4")
  inspect(sm2_quality(Grade::Easy), content="5")
  // 与展示用刻度明确不同
  inspect(Grade::to_int(Grade::Again), content="0")
  inspect(Grade::to_int(Grade::Good), content="3")
}

///|
test "答错判定是 q < 3，只有 Again 算错" {
  inspect(sm2_is_correct(Grade::Again), content="false")
  // Hard 算答对：q=3 >= 3，且 is_recalled(Hard) 也为 true（二者一致）
  inspect(is_recalled(Grade::Hard), content="true")
  inspect(sm2_is_correct(Grade::Hard), content="true")
  inspect(sm2_is_correct(Grade::Good), content="true")
  inspect(sm2_is_correct(Grade::Easy), content="true")
  // sm2_is_correct 与全项目统一的 is_recalled 必须完全等价
  for g in [Grade::Again, Grade::Hard, Grade::Good, Grade::Easy] {
    inspect(sm2_is_correct(g) == is_recalled(g), content="true")
  }
}

///|
test "EF delta 四个值" {
  assert_true(approx(sm2_ease_delta(5), 0.1, 0.000000001))
  assert_true(approx(sm2_ease_delta(4), 0.0, 0.000000001))
  assert_true(approx(sm2_ease_delta(3), -0.14, 0.000000001))
  assert_true(approx(sm2_ease_delta(2), -0.32, 0.000000001))
}

///|
test "sm2_next_ease 单步" {
  assert_true(approx(sm2_next_ease(2.5, Grade::Easy), 2.6, 0.000000001))
  assert_true(approx(sm2_next_ease(2.5, Grade::Good), 2.5, 0.000000001))
  assert_true(approx(sm2_next_ease(2.5, Grade::Hard), 2.36, 0.000000001))
  assert_true(approx(sm2_next_ease(2.5, Grade::Again), 2.18, 0.000000001))
}

///|
test "EF 下限 1.3：连续 Again 不会击穿" {
  let sched = Sm2::new()
  let mut state = sched.init("c1", 0L)
  let mut now : Timestamp = 0L
  // 连续 20 次 Again（2.18 → 1.86 → 1.54 → 1.3 之后恒定）
  for i in 0..<20 {
    state = sched.review(state, Grade::Again, now)
    now = state.due
    let ef = state.difficulty
    assert_true(ef >= 1.3)
  }
  // 收敛到下限
  assert_true(approx(state.difficulty, 1.3, 0.000000001))
}

///|
test "EF 下限 1.3：下限之后 Easy 只回升 0.1" {
  let sched = Sm2::new()
  let mut state = sm2_state_at_floor(sched)
  state = sched.review(state, Grade::Easy, 0L)
  assert_true(approx(state.difficulty, 1.4, 0.000000001))
}

///|
/// 一路 Again 把 EF 压到下限，返回那个状态。
fn sm2_state_at_floor(sched : Sm2) -> CardState {
  let mut state = sched.init("c1", 0L)
  let mut now : Timestamp = 0L
  for i in 0..<10 {
    state = sched.review(state, Grade::Again, now)
    now = state.due
  }
  state
}

// ─────────────────────────────────────────────────────────────────
// 外来 CardState 的防御性处理
// ─────────────────────────────────────────────────────────────────

///|
/// 外来 CardState 的 difficulty < 1.3 时必须被夹到 1.3，
/// 而不是静默换成本调度器自己的默认 EF（Sm2::new() 是 2.5）。
///
/// 场景：CardState 是 pub(all) 结构，任何调用方都能构造（或从旧版本
/// 数据恢复出）difficulty=0.5 这类低于下限的状态。review 收到后：
/// - 修复前：prev_ease 直接回退到 self.ease_factor=2.5 —— 一张难度
///   顶格的卡凭空「舒展」成 2.5，下次间隔按 2.5 倍膨胀。
/// - 修复后：prev_ease 夹到 sm2_min_ease()=1.3 —— 尊重"这张卡很难"
///   的事实，间隔按 1.3 倍起步。
/// Good 不改 EF，所以最终 difficulty 精确等于夹取值，断言可写成等值。
test "外来低 EF 状态被夹到 1.3 而不是换回默认 2.5" {
  let sched = Sm2::new()
  let foreign = {
    ..sched.init("c1", 0L),
    difficulty: 0.5,
    reps: 3,
    interval_days: 20.0,
  }
  let out = sched.review(foreign, Grade::Good, 0L)
  // 修复前这里是 2.5（回退默认 EF），修复后应为 1.3
  assert_true(approx(out.difficulty, 1.3, 0.000000001))
  // 间隔也应按夹取后的 1.3 算：round(20 * 1.3) = 26，
  // 而不是按 2.5 的 round(20 * 2.5) = 50
  assert_true(approx(out.interval_days, 26.0, 0.000000001))
}

///|
/// 正常范围（>=1.3）的外来 EF 不受影响：2.4 会被原样使用。
test "外来正常 EF 状态原样使用" {
  let sched = Sm2::new()
  let foreign = {
    ..sched.init("c1", 0L),
    difficulty: 2.4,
    reps: 3,
    interval_days: 20.0,
  }
  let out = sched.review(foreign, Grade::Good, 0L)
  assert_true(approx(out.difficulty, 2.4, 0.000000001))
  // round(20 * 2.4) = 48
  assert_true(approx(out.interval_days, 48.0, 0.000000001))
}

///|
test "间隔随 reps 单调不减（Good 序列）" {
  let sched = Sm2::new()
  let mut state = sched.init("c1", 0L)
  let mut now : Timestamp = 0L
  let mut prev = 0.0
  for i in 0..<8 {
    state = sched.review(state, Grade::Good, now)
    now = state.due
    let cur = state.interval_days
    assert_true(cur >= prev)
    prev = cur
  }
}

///|
test "同一状态 Good 的间隔 >= Hard 的间隔" {
  let sched = Sm2::new()
  let base = {
    ..sched.init("c1", 0L),
    reps: 3,
    interval_days: 20.0,
    difficulty: 2.5,
  }
  let good = sched.review(base, Grade::Good, 0L)
  let hard = sched.review(base, Grade::Hard, 0L)
  assert_true(good.interval_days >= hard.interval_days)
}

// ─────────────────────────────────────────────────────────────────
// 状态推进的非表格部分
// ─────────────────────────────────────────────────────────────────

///|
test "init 是新卡" {
  let sched = Sm2::new()
  let st = sched.init("c1", 1000L)
  inspect(st.card_id, content="c1")
  inspect(st.reps, content="0")
  inspect(st.lapses, content="0")
  inspect(st.due.to_string(), content="1000")
  inspect(st.last_review.to_string(), content="1000")
  assert_true(approx(st.interval_days, 0.0, 0.000000001))
  // EF 初值写进 difficulty
  assert_true(approx(st.difficulty, 2.5, 0.000000001))
  inspect(Phase::label(st.phase), content="新卡")
}

///|
test "review 不修改入参（纯函数）" {
  let sched = Sm2::new()
  let st = sched.init("c1", 0L)
  let _ = sched.review(st, Grade::Good, 0L)
  inspect(st.reps, content="0")
  assert_true(approx(st.interval_days, 0.0, 0.000000001))
}

///|
test "due 按间隔推进" {
  let sched = Sm2::new()
  let st = sched.init("c1", 0L)
  let s1 = sched.review(st, Grade::Good, 0L)
  // 首次间隔 1 天 → due = 0 + 86400
  inspect(s1.due.to_string(), content="86400")
  let s2 = sched.review(s1, Grade::Good, s1.due)
  // 第二次间隔 6 天，从 s1.due(=86400) 起算 → 86400 + 6*86400 = 604800
  inspect(s2.due.to_string(), content="604800")
  let s3 = sched.review(s2, Grade::Good, s2.due)
  // 第三次间隔 15 天，从 s2.due 起算 → 604800 + 15*86400 = 1900800
  inspect(s3.due.to_string(), content="1900800")
}

///|
test "lapses 只在答错时增加" {
  let sched = Sm2::new()
  let mut state = sched.init("c1", 0L)
  state = sched.review(state, Grade::Good, 0L)
  inspect(state.lapses, content="0")
  state = sched.review(state, Grade::Again, 0L)
  inspect(state.lapses, content="1")
  state = sched.review(state, Grade::Again, 0L)
  inspect(state.lapses, content="2")
}

///|
test "reps 答对累加、答错归零" {
  let sched = Sm2::new()
  let mut state = sched.init("c1", 0L)
  state = sched.review(state, Grade::Good, 0L)
  inspect(state.reps, content="1")
  state = sched.review(state, Grade::Good, 0L)
  inspect(state.reps, content="2")
  state = sched.review(state, Grade::Again, 0L)
  inspect(state.reps, content="0")
  state = sched.review(state, Grade::Good, 0L)
  inspect(state.reps, content="1")
}

///|
test "phase 随进度推进" {
  let sched = Sm2::new()
  let mut state = sched.init("c1", 0L)
  // reps 1 → Learning
  state = sched.review(state, Grade::Good, 0L)
  inspect(Phase::label(state.phase), content="学习中")
  // reps 2 → Learning
  state = sched.review(state, Grade::Good, 0L)
  inspect(Phase::label(state.phase), content="学习中")
  // reps 3 → Review
  state = sched.review(state, Grade::Good, 0L)
  inspect(Phase::label(state.phase), content="复习")
  // 答错 → Relearning
  state = sched.review(state, Grade::Again, 0L)
  inspect(Phase::label(state.phase), content="重学")
}

///|
test "name 是 sm2" {
  inspect(Sm2::new().name(), content="sm2")
}

///|
test "desired_retention 固定 0.9" {
  let r = Sm2::new().desired_retention()
  assert_true(approx(r, 0.9, 0.000000001))
}

// ─────────────────────────────────────────────────────────────────
// retrievability（近似值）
// ─────────────────────────────────────────────────────────────────

///|
test "retrievability 在复习时刻为 1" {
  let sched = Sm2::new()
  let st = sched.init("c1", 0L)
  let r = sched.retrievability(st, 0L)
  assert_true(approx(r, 1.0, 0.000000001))
}

///|
test "retrievability 在 t=S 处约为 0.9（校准点）" {
  let sched = Sm2::new()
  // 造一个 interval_days = 10 的状态
  let st = { ..sched.init("c1", 0L), interval_days: 10.0, stability: 10.0, }
  // t = 10 天
  let r = sched.retrievability(st, 864000L)
  assert_true(approx(r, 0.9, 0.000000001))
}

///|
test "retrievability 随时间单调下降" {
  let sched = Sm2::new()
  let st = { ..sched.init("c1", 0L), interval_days: 10.0, stability: 10.0, }
  let mut prev = 1.1
  for d in [0, 1, 2, 5, 10, 20, 50] {
    let now : Timestamp = Int32::to_int64(d) * 86400L
    let r = sched.retrievability(st, now)
    assert_true(r <= prev)
    assert_true(r >= 0.0)
    assert_true(r <= 1.0)
    prev = r
  }
}

///|
test "retrievability 值域夹在 [0,1]" {
  let sched = Sm2::new()
  let st = { ..sched.init("c1", 0L), interval_days: 1.0, stability: 1.0, }
  // 极端逾期 1000 天
  let r = sched.retrievability(st, 1000L * 86400L)
  assert_true(r >= 0.0)
  assert_true(r <= 1.0)
}

///|
test "retrievability 对无间隔的新卡用 1 天兜底" {
  let sched = Sm2::new()
  let st = sched.init("c1", 0L) // interval_days = 0
  // 1 天后：0.9^(1/1) = 0.9
  let r = sched.retrievability(st, 86400L)
  assert_true(approx(r, 0.9, 0.000001))
}
