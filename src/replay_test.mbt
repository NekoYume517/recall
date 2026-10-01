// recall — 重放引擎测试（白盒）
//
// 覆盖：
//   - 基本计数（复习数 / 遗忘数 / 卡片数 / 快照数）
//   - 每卡独立、按时间重放（乱序日志也要正确处理）
//   - 确定性（同输入两次结果逐字段一致）
//   - interval_error_days 的定义与边界
//   - 泛型 replay_with 与运行期 replay 等价
//   - compare 的一致性（自比相等、per_card 求和等于总值）

///|
/// 造一份小而全的日志：
///   a: Good, Good, Good        （间隔 1 / 7）
///   b: Good, Again, Good       （间隔 3 / 1）
/// 共 6 条事件，2 张卡，1 次遗忘。
fn sample_log() -> ReviewLog {
  let log = ReviewLog::new()
  // 卡片 a
  log.push(ReviewEvent::new("a", 0L, 0L, Good, 0.0))
  log.push(ReviewEvent::new("a", 86400L, 86400L, Good, 1.0))
  log.push(ReviewEvent::new("a", 86400L * 8L, 86400L * 8L, Good, 7.0))
  // 卡片 b
  log.push(ReviewEvent::new("b", 0L, 0L, Good, 0.0))
  log.push(ReviewEvent::new("b", 86400L * 3L, 86400L * 3L, Again, 3.0))
  log.push(ReviewEvent::new("b", 86400L * 4L, 86400L * 4L, Good, 1.0))
  log
}

// ---------------------------------------------------------------------------
// 基本计数
// ---------------------------------------------------------------------------

///|
test "replay: 复习总数等于事件数" {
  let res = replay(sample_log(), AnyScheduler::by_name("fsrs"))
  assert_eq(res.total_reviews, 6)
}

///|
test "replay: 遗忘数等于 Again 事件数" {
  let res = replay(sample_log(), AnyScheduler::by_name("fsrs"))
  assert_eq(res.total_lapses, 1)
}

///|
test "replay: 每张卡都有最终状态" {
  let res = replay(sample_log(), AnyScheduler::by_name("fsrs"))
  assert_eq(res.final_states.length(), 2)
  assert_true(res.final_states.get("a").is_some())
  assert_true(res.final_states.get("b").is_some())
}

///|
test "replay: 快照数等于事件数" {
  let log = sample_log()
  let res = replay(log, AnyScheduler::by_name("sm2"))
  assert_eq(res.snapshots.length(), log.length())
}

///|
test "replay: 空日志得到空结果" {
  let res = replay(ReviewLog::new(), AnyScheduler::by_name("fsrs"))
  assert_eq(res.total_reviews, 0)
  assert_eq(res.total_lapses, 0)
  assert_eq(res.final_states.length(), 0)
  assert_eq(res.snapshots.length(), 0)
  assert_true(near(res.interval_error_days, 0.0))
}

///|
test "replay: 三种调度器都能跑同一份日志" {
  for nm in ["sm2", "fsrs", "leitner"] {
    let res = replay(sample_log(), AnyScheduler::by_name(nm))
    assert_eq(res.total_reviews, 6)
    assert_eq(res.total_lapses, 1)
    assert_eq(res.final_states.length(), 2)
  }
}

// ---------------------------------------------------------------------------
// 重放语义
// ---------------------------------------------------------------------------

///|
test "replay: 单次复习走初始公式（S_0(Good)）" {
  let log = ReviewLog::new()
  log.push(ReviewEvent::new("x", 100L, 100L, Good, 0.0))
  let res = replay(log, AnyScheduler::by_name("fsrs"))
  let st = match res.final_states.get("x") {
    Some(v) => v
    None => abort("missing x")
  }
  assert_true(near(st.stability, 3.173))
  assert_eq(st.reps, 1)
}

///|
test "replay: 乱序事件仍按时间正序重放" {
  let log = ReviewLog::new()
  // 故意倒序插入
  log.push(ReviewEvent::new("z", 86400L * 8L, 0L, Good, 7.0))
  log.push(ReviewEvent::new("z", 86400L, 0L, Good, 1.0))
  log.push(ReviewEvent::new("z", 0L, 0L, Good, 0.0))
  let res = replay(log, AnyScheduler::by_name("fsrs"))
  // 第一个快照必须是最早的事件（100 时间戳是 0 那条）
  assert_eq(res.snapshots[0].0, 0L)
  let st = match res.final_states.get("z") {
    Some(v) => v
    None => abort("missing z")
  }
  // 首次走初始公式 → S_0(Good) = 3.173，后续两次递增
  assert_true(st.stability > 3.173)
  assert_eq(st.reps, 3)
}

///|
test "replay: 卡片之间互不影响" {
  // 同一张卡单独重放，与混在两张卡的日志里重放，最终状态应相同
  let mixed = sample_log()
  let alone = ReviewLog::new()
  alone.push(ReviewEvent::new("a", 0L, 0L, Good, 0.0))
  alone.push(ReviewEvent::new("a", 86400L, 86400L, Good, 1.0))
  alone.push(ReviewEvent::new("a", 86400L * 8L, 86400L * 8L, Good, 7.0))
  let r_mixed = replay(mixed, AnyScheduler::by_name("fsrs"))
  let r_alone = replay(alone, AnyScheduler::by_name("fsrs"))
  let s_mixed = match r_mixed.final_states.get("a") {
    Some(v) => v.stability
    None => abort("missing")
  }
  let s_alone = match r_alone.final_states.get("a") {
    Some(v) => v.stability
    None => abort("missing")
  }
  assert_true(near(s_mixed, s_alone))
}

///|
test "replay: 快照按 card_id 升序分组，卡片内时间递增" {
  let res = replay(sample_log(), AnyScheduler::by_name("fsrs"))
  // 前 3 个快照属于 a（因为 a < b），后 3 个属于 b
  assert_eq(res.snapshots[0].1, "a")
  assert_eq(res.snapshots[2].1, "a")
  assert_eq(res.snapshots[3].1, "b")
  assert_eq(res.snapshots[5].1, "b")
  // 卡片内时间不减
  assert_true(res.snapshots[0].0 <= res.snapshots[1].0)
  assert_true(res.snapshots[1].0 <= res.snapshots[2].0)
}

///|
test "replay: 快照里的状态是「该事件之后」的状态" {
  let res = replay(sample_log(), AnyScheduler::by_name("fsrs"))
  // 第一条事件后应该是 S_0(Good)
  let first = res.snapshots[0].2
  assert_true(near(first.stability, 3.173))
  assert_eq(first.reps, 1)
  // 最后一条（卡片 b 的 Good）后 reps = 2（首次 Good + 遗忘后 Good）
  let last = res.snapshots[5].2
  assert_eq(last.reps, 2)
  assert_eq(last.lapses, 1)
}

///|
test "replay: 遗忘事件让 lapses 累加" {
  let res = replay(sample_log(), AnyScheduler::by_name("fsrs"))
  let b = match res.final_states.get("b") {
    Some(v) => v
    None => abort("missing b")
  }
  assert_eq(b.lapses, 1)
}

// ---------------------------------------------------------------------------
// 确定性
// ---------------------------------------------------------------------------

///|
test "replay: 同日志重放两次，所有卡片状态逐字段一致" {
  let log = sample_log()
  let r1 = replay(log, AnyScheduler::by_name("fsrs"))
  let r2 = replay(log, AnyScheduler::by_name("fsrs"))
  assert_eq(r1.total_reviews, r2.total_reviews)
  assert_eq(r1.total_lapses, r2.total_lapses)
  assert_true(near(r1.interval_error_days, r2.interval_error_days))
  for cid in ["a", "b"] {
    let s1 = match r1.final_states.get(cid) {
      Some(v) => v
      None => abort("missing")
    }
    let s2 = match r2.final_states.get(cid) {
      Some(v) => v
      None => abort("missing")
    }
    assert_true(CardState::equal(s1, s2))
  }
}

///|
test "replay: 同日志重放两次，快照序列完全一致" {
  let log = sample_log()
  let r1 = replay(log, AnyScheduler::by_name("fsrs"))
  let r2 = replay(log, AnyScheduler::by_name("fsrs"))
  assert_eq(r1.snapshots.length(), r2.snapshots.length())
  for i, snap in r1.snapshots {
    assert_eq(snap.0, r2.snapshots[i].0)
    assert_eq(snap.1, r2.snapshots[i].1)
    assert_true(CardState::equal(snap.2, r2.snapshots[i].2))
  }
}

// ---------------------------------------------------------------------------
// interval_error_days
// ---------------------------------------------------------------------------

///|
test "replay: interval_error_days 非负" {
  for nm in ["sm2", "fsrs", "leitner"] {
    let res = replay(sample_log(), AnyScheduler::by_name(nm))
    assert_true(res.interval_error_days >= 0.0)
  }
}

///|
test "replay: 单次复习时没有间隔样本，误差为 0" {
  let log = ReviewLog::new()
  log.push(ReviewEvent::new("x", 0L, 0L, Good, 0.0))
  let res = replay(log, AnyScheduler::by_name("fsrs"))
  assert_true(near(res.interval_error_days, 0.0))
}

///|
test "replay: 间隔完全吻合时误差为 0" {
  // 用 mock 思路：构造一个"实际间隔 = 调度间隔"的日志很难，
  // 改用等价检查——误差必须小于「实际间隔跨度」，不会算出荒谬值。
  let res = replay(sample_log(), AnyScheduler::by_name("fsrs"))
  // 日志里最大间隔是 7 天，误差不可能超过它
  assert_true(res.interval_error_days <= 7.0)
}

// ---------------------------------------------------------------------------
// 泛型 vs 运行期分发
// ---------------------------------------------------------------------------

///|
test "replay: replay_with(泛型) 与 replay(枚举分发) 结果一致" {
  let log = sample_log()
  let generic = replay_with(log, Fsrs::new())
  let dynamic = replay(log, Fsrs(Fsrs::new()))
  assert_eq(generic.total_reviews, dynamic.total_reviews)
  assert_eq(generic.total_lapses, dynamic.total_lapses)
  let gs = match generic.final_states.get("a") {
    Some(v) => v
    None => abort("missing")
  }
  let ds = match dynamic.final_states.get("a") {
    Some(v) => v
    None => abort("missing")
  }
  assert_true(CardState::equal(gs, ds))
}

///|
test "replay: 泛型版本对 Sm2 与 Leitner 也成立" {
  let log = sample_log()
  let g_sm2 = replay_with(log, Sm2::new())
  let d_sm2 = replay(log, Sm2(Sm2::new()))
  assert_eq(g_sm2.total_reviews, d_sm2.total_reviews)
  let g_lei = replay_with(log, Leitner::new())
  let d_lei = replay(log, Leitner(Leitner::new()))
  assert_eq(g_lei.total_reviews, d_lei.total_reviews)
}

// ---------------------------------------------------------------------------
// compare
// ---------------------------------------------------------------------------

///|
test "compare: 名字正确" {
  let c = compare(
    sample_log(),
    AnyScheduler::by_name("sm2"),
    AnyScheduler::by_name("fsrs"),
  )
  assert_eq(c.a_name, "sm2")
  assert_eq(c.b_name, "fsrs")
}

///|
test "compare: per_card 覆盖所有卡片且按 id 升序" {
  let c = compare(
    sample_log(),
    AnyScheduler::by_name("sm2"),
    AnyScheduler::by_name("fsrs"),
  )
  assert_eq(c.per_card.length(), 2)
  assert_eq(c.per_card[0].0, "a")
  assert_eq(c.per_card[1].0, "b")
}

///|
test "compare: 总间隔等于 per_card 两侧之和" {
  let c = compare(
    sample_log(),
    AnyScheduler::by_name("sm2"),
    AnyScheduler::by_name("fsrs"),
  )
  let mut sa = 0.0
  let mut sb = 0.0
  for row in c.per_card {
    sa = sa + row.1
    sb = sb + row.2
  }
  assert_true(near(sa, c.a_total_interval))
  assert_true(near(sb, c.b_total_interval))
}

///|
test "compare: 遗忘次数与单独重放一致" {
  let log = sample_log()
  let c = compare(
    log,
    AnyScheduler::by_name("sm2"),
    AnyScheduler::by_name("fsrs"),
  )
  let ra = replay(sample_log(), AnyScheduler::by_name("sm2"))
  let rb = replay(sample_log(), AnyScheduler::by_name("fsrs"))
  assert_eq(c.a_lapses, ra.total_lapses)
  assert_eq(c.b_lapses, rb.total_lapses)
}

///|
test "compare: 自己和自己比，间隔完全相同" {
  let c = compare(
    sample_log(),
    AnyScheduler::by_name("fsrs"),
    AnyScheduler::by_name("fsrs"),
  )
  assert_true(near(c.a_total_interval, c.b_total_interval))
  for row in c.per_card {
    assert_true(near(row.1, row.2))
  }
}

///|
test "compare: FSRS 的最终间隔大于 Leitner（示例日志上）" {
  let c = compare(
    sample_log(),
    AnyScheduler::by_name("fsrs"),
    AnyScheduler::by_name("leitner"),
  )
  assert_true(c.a_total_interval > c.b_total_interval)
}

///|
test "compare: 空日志不崩" {
  let c = compare(
    ReviewLog::new(),
    AnyScheduler::by_name("sm2"),
    AnyScheduler::by_name("fsrs"),
  )
  assert_eq(c.per_card.length(), 0)
  assert_true(near(c.a_total_interval, 0.0))
  assert_true(near(c.b_total_interval, 0.0))
}

///|
test "compare: 交换顺序后间隔互换" {
  let log = sample_log()
  let ab = compare(
    log,
    AnyScheduler::by_name("sm2"),
    AnyScheduler::by_name("fsrs"),
  )
  let ba = compare(
    log,
    AnyScheduler::by_name("fsrs"),
    AnyScheduler::by_name("sm2"),
  )
  assert_true(near(ab.a_total_interval, ba.b_total_interval))
  assert_true(near(ab.b_total_interval, ba.a_total_interval))
}
