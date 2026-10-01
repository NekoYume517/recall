// recall — 模拟器测试（白盒）
//
// 最重要的两条：
//   1. **确定性**：同配置跑两次，逐日字段完全一致
//   2. **单调性**：new_per_day=0 时积压单调不增
//
// 其余覆盖：复习上限、策略差异、边界（days=0）、LCG 自身性质。

///|
/// 造配置的便捷函数。
fn cfg_of(
  days : Int32,
  new_per_day : Int32,
  review_limit : Int32,
  policy : String,
) -> SimConfig {
  {
    days,
    new_per_day,
    review_limit,
    desired_retention: 0.9,
    grade_fn: grade_policy(policy),
    seed: 20240101L,
  }
}

// ---------------------------------------------------------------------------
// 形状与边界
// ---------------------------------------------------------------------------

///|
test "simulate: 输出天数与配置一致" {
  let res = simulate(
    AnyScheduler::by_name("fsrs"),
    cfg_of(10, 2, 0, "optimistic"),
  )
  assert_eq(res.days.length(), 10)
  assert_eq(res.days[0].day, 0)
  assert_eq(res.days[9].day, 9)
}

///|
test "simulate: days=0 得到空结果" {
  let res = simulate(
    AnyScheduler::by_name("fsrs"),
    cfg_of(0, 5, 0, "optimistic"),
  )
  assert_eq(res.days.length(), 0)
  assert_eq(res.total_reviews, 0)
  assert_eq(res.final_backlog, 0)
  assert_eq(res.max_backlog, 0)
}

///|
test "simulate: 三种调度器都能跑" {
  for nm in ["sm2", "fsrs", "leitner"] {
    let res = simulate(
      AnyScheduler::by_name(nm),
      cfg_of(15, 3, 0, "optimistic"),
    )
    assert_eq(res.days.length(), 15)
    assert_true(res.total_reviews > 0)
  }
}

///|
test "simulate: SimConfig::default 能直接跑" {
  let res = simulate(AnyScheduler::by_name("fsrs"), SimConfig::default())
  assert_eq(res.days.length(), 90)
  assert_true(res.total_reviews > 0)
}

// ---------------------------------------------------------------------------
// 确定性（硬性要求）
// ---------------------------------------------------------------------------

///|
test "simulate: 同配置跑两次，逐日字段完全一致" {
  let r1 = simulate(
    AnyScheduler::by_name("fsrs"),
    cfg_of(30, 5, 20, "realistic"),
  )
  let r2 = simulate(
    AnyScheduler::by_name("fsrs"),
    cfg_of(30, 5, 20, "realistic"),
  )
  assert_eq(r1.total_reviews, r2.total_reviews)
  assert_eq(r1.max_backlog, r2.max_backlog)
  assert_eq(r1.final_backlog, r2.final_backlog)
  assert_eq(r1.days.length(), r2.days.length())
  for i, d1 in r1.days {
    let d2 = r2.days[i]
    assert_eq(d1.day, d2.day)
    assert_eq(d1.new_cards, d2.new_cards)
    assert_eq(d1.due_cards, d2.due_cards)
    assert_eq(d1.reviewed, d2.reviewed)
    assert_eq(d1.backlog, d2.backlog)
    assert_eq(d1.retained, d2.retained)
  }
}

///|
test "simulate: pessimistic 也完全确定" {
  let r1 = simulate(
    AnyScheduler::by_name("fsrs"),
    cfg_of(25, 4, 10, "pessimistic"),
  )
  let r2 = simulate(
    AnyScheduler::by_name("fsrs"),
    cfg_of(25, 4, 10, "pessimistic"),
  )
  for i, d1 in r1.days {
    assert_eq(d1.backlog, r2.days[i].backlog)
    assert_eq(d1.retained, r2.days[i].retained)
  }
}

///|
test "simulate: 90 天基准场景可复现" {
  let a = simulate(
    AnyScheduler::by_name("fsrs"),
    cfg_of(90, 20, 200, "optimistic"),
  )
  let b = simulate(
    AnyScheduler::by_name("fsrs"),
    cfg_of(90, 20, 200, "optimistic"),
  )
  assert_eq(a.final_backlog, b.final_backlog)
  assert_eq(a.total_reviews, b.total_reviews)
  assert_eq(a.max_backlog, b.max_backlog)
  assert_eq(a.days.length(), 90)
}

///|
test "simulate: 不同种子给出不同轨迹" {
  let c1 = cfg_of(40, 6, 0, "realistic")
  let c2 : SimConfig = {
    days: 40,
    new_per_day: 6,
    review_limit: 0,
    desired_retention: 0.9,
    grade_fn: grade_policy_with_seed("realistic", 999L),
    seed: 999L,
  }
  let r1 = simulate(AnyScheduler::by_name("fsrs"), c1)
  let r2 = simulate(AnyScheduler::by_name("fsrs"), c2)
  // 种子不同，保留数不可能逐日完全相同
  let mut differ = false
  for i, d1 in r1.days {
    if d1.retained != r2.days[i].retained {
      differ = true
    }
  }
  assert_true(differ)
}

// ---------------------------------------------------------------------------
// 单调性与守恒
// ---------------------------------------------------------------------------

///|
test "simulate: new_per_day=0 时不产生新卡、不复习、不积压" {
  let res = simulate(
    AnyScheduler::by_name("fsrs"),
    cfg_of(20, 0, 0, "optimistic"),
  )
  for d in res.days {
    assert_eq(d.new_cards, 0)
    assert_eq(d.due_cards, 0)
    assert_eq(d.reviewed, 0)
    assert_eq(d.backlog, 0)
  }
  assert_eq(res.total_reviews, 0)
  assert_eq(res.final_backlog, 0)
}

///|
test "simulate: new_per_day=0 且用 pessimistic 仍不积压" {
  let res = simulate(
    AnyScheduler::by_name("fsrs"),
    cfg_of(30, 0, 0, "pessimistic"),
  )
  for d in res.days {
    assert_eq(d.backlog, 0)
  }
}

///|
test "simulate: total_reviews 等于各天 reviewed 之和" {
  let res = simulate(
    AnyScheduler::by_name("fsrs"),
    cfg_of(25, 4, 15, "realistic"),
  )
  let mut sum = 0
  for d in res.days {
    sum = sum + d.reviewed
  }
  assert_eq(sum, res.total_reviews)
}

///|
test "simulate: max_backlog 是各天 backlog 的最大值" {
  let res = simulate(
    AnyScheduler::by_name("fsrs"),
    cfg_of(40, 8, 10, "pessimistic"),
  )
  let mut mx = 0
  for d in res.days {
    if d.backlog > mx {
      mx = d.backlog
    }
  }
  assert_eq(mx, res.max_backlog)
}

///|
test "simulate: final_backlog 是最后一天的 backlog" {
  let res = simulate(
    AnyScheduler::by_name("fsrs"),
    cfg_of(20, 5, 3, "realistic"),
  )
  assert_eq(res.final_backlog, res.days[19].backlog)
}

///|
test "simulate: retained <= reviewed" {
  let res = simulate(
    AnyScheduler::by_name("fsrs"),
    cfg_of(30, 5, 0, "realistic"),
  )
  for d in res.days {
    assert_true(d.retained <= d.reviewed)
  }
}

///|
test "simulate: reviewed <= due_cards 且 <= review_limit" {
  let res = simulate(
    AnyScheduler::by_name("fsrs"),
    cfg_of(40, 10, 7, "realistic"),
  )
  for d in res.days {
    assert_true(d.reviewed <= d.due_cards)
    assert_true(d.reviewed <= 7)
  }
}

///|
test "simulate: 每天新增不超过 new_per_day" {
  let res = simulate(
    AnyScheduler::by_name("fsrs"),
    cfg_of(20, 7, 0, "optimistic"),
  )
  for d in res.days {
    assert_true(d.new_cards <= 7)
  }
}

// ---------------------------------------------------------------------------
// 积压行为（项目的核心问题）
// ---------------------------------------------------------------------------

///|
test "simulate: 复习上限过低必然积压" {
  // 每天 20 张新卡但只复习 3 张 → 积压线性增长
  let res = simulate(
    AnyScheduler::by_name("fsrs"),
    cfg_of(20, 20, 3, "optimistic"),
  )
  assert_true(res.final_backlog > 0)
  assert_true(res.max_backlog >= res.final_backlog)
}

///|
test "simulate: 复习不限 + optimistic 不产生积压" {
  let res = simulate(
    AnyScheduler::by_name("fsrs"),
    cfg_of(60, 10, 0, "optimistic"),
  )
  assert_eq(res.final_backlog, 0)
}

///|
test "simulate: 复习上限充足时 optimistic 不积压" {
  let res = simulate(
    AnyScheduler::by_name("fsrs"),
    cfg_of(90, 20, 200, "optimistic"),
  )
  assert_eq(res.final_backlog, 0)
}

///|
test "simulate: pessimistic 更容易积压" {
  let opt = simulate(
    AnyScheduler::by_name("fsrs"),
    cfg_of(60, 10, 0, "optimistic"),
  )
  let pes = simulate(
    AnyScheduler::by_name("fsrs"),
    cfg_of(60, 10, 0, "pessimistic"),
  )
  // 两种都不限复习，积压都应为 0，但 pessimistic 复习次数明显更多
  assert_true(pes.total_reviews > opt.total_reviews)
}

///|
test "simulate: 复习上限固定时，pessimistic 积压 >= optimistic" {
  let opt = simulate(
    AnyScheduler::by_name("fsrs"),
    cfg_of(60, 10, 30, "optimistic"),
  )
  let pes = simulate(
    AnyScheduler::by_name("fsrs"),
    cfg_of(60, 10, 30, "pessimistic"),
  )
  assert_true(pes.final_backlog >= opt.final_backlog)
}

// ---------------------------------------------------------------------------
// 策略语义
// ---------------------------------------------------------------------------

///|
test "simulate: optimistic 每次都给 Good，全部记住" {
  let res = simulate(
    AnyScheduler::by_name("fsrs"),
    cfg_of(15, 3, 0, "optimistic"),
  )
  for d in res.days {
    assert_eq(d.retained, d.reviewed)
  }
}

///|
test "simulate: realistic 会有遗忘" {
  let res = simulate(
    AnyScheduler::by_name("fsrs"),
    cfg_of(40, 5, 0, "realistic"),
  )
  let mut retained = 0
  for d in res.days {
    retained = retained + d.retained
  }
  assert_true(retained < res.total_reviews)
}

///|
test "simulate: realistic 的长期保持率接近目标保持率" {
  // 目标 0.9，长期实际保持率应在 0.8 附近或以上（策略按 R 抽样，R 从 1 衰减到 0.9）
  let res = simulate(
    AnyScheduler::by_name("fsrs"),
    cfg_of(120, 10, 0, "realistic"),
  )
  let mut retained = 0
  for d in res.days {
    retained = retained + d.retained
  }
  let rate = retained.to_double() / res.total_reviews.to_double()
  assert_true(rate > 0.7)
  assert_true(rate <= 1.0)
}

///|
test "simulate: pessimistic 的保持率低于 realistic" {
  let real = simulate(
    AnyScheduler::by_name("fsrs"),
    cfg_of(60, 5, 0, "realistic"),
  )
  let pes = simulate(
    AnyScheduler::by_name("fsrs"),
    cfg_of(60, 5, 0, "pessimistic"),
  )
  let mut rr = 0
  for d in real.days {
    rr = rr + d.retained
  }
  let mut pr = 0
  for d in pes.days {
    pr = pr + d.retained
  }
  let r_rate = rr.to_double() / real.total_reviews.to_double()
  let p_rate = pr.to_double() / pes.total_reviews.to_double()
  assert_true(p_rate < r_rate)
}

// ---------------------------------------------------------------------------
// grade_policy
// ---------------------------------------------------------------------------

///|
test "simulate: grade_policy 未知名字退回 optimistic" {
  let p = grade_policy("nonsense")
  let st = Fsrs::new().init("x", 0L)
  assert_eq(p(st), Good)
}

///|
test "simulate: optimistic 恒定返回 Good" {
  let p = grade_policy("optimistic")
  let st = Fsrs::new().init("x", 0L)
  let mut i = 0
  while i < 20 {
    assert_eq(p(st), Good)
    i = i + 1
  }
}

///|
test "simulate: realistic 会给出多种评分" {
  let p = grade_policy("realistic")
  let st = Fsrs::new().init("x", 0L)
  let seen = Array::make(4, false)
  let mut i = 0
  while i < 300 {
    let g = p(st)
    match g {
      Again => seen[0] = true
      Hard => seen[1] = true
      Good => seen[2] = true
      Easy => seen[3] = true
    }
    i = i + 1
  }
  let mut distinct = 0
  for v in seen {
    if v {
      distinct = distinct + 1
    }
  }
  assert_true(distinct >= 2)
}

///|
test "simulate: pessimistic 产生的 Again 比 realistic 多" {
  let real = grade_policy_with_seed("realistic", 4242L)
  let pes = grade_policy_with_seed("pessimistic", 4242L)
  let st = Fsrs::new().init("x", 0L)
  let mut real_fail = 0
  let mut pes_fail = 0
  let mut i = 0
  while i < 500 {
    if real(st) == Again {
      real_fail = real_fail + 1
    }
    if pes(st) == Again {
      pes_fail = pes_fail + 1
    }
    i = i + 1
  }
  assert_true(pes_fail > real_fail)
}

///|
test "simulate: 同种子 realistic 序列完全相同" {
  let p1 = grade_policy_with_seed("realistic", 777L)
  let p2 = grade_policy_with_seed("realistic", 777L)
  let st = Fsrs::new().init("x", 0L)
  let mut i = 0
  while i < 100 {
    assert_eq(p1(st), p2(st))
    i = i + 1
  }
}

///|
test "simulate: 不同种子 realistic 序列不同" {
  let p1 = grade_policy_with_seed("realistic", 111L)
  let p2 = grade_policy_with_seed("realistic", 222L)
  let st = Fsrs::new().init("x", 0L)
  let mut differ = false
  let mut i = 0
  while i < 100 {
    if p1(st) != p2(st) {
      differ = true
    }
    i = i + 1
  }
  assert_true(differ)
}

///|
test "simulate: grade_policy_valid 只认三个名字" {
  assert_true(grade_policy_valid("optimistic"))
  assert_true(grade_policy_valid("realistic"))
  assert_true(grade_policy_valid("pessimistic"))
  assert_true(!grade_policy_valid("random"))
  assert_true(!grade_policy_valid(""))
}

///|
test "simulate: grade_policy_valid 大小写不敏感" {
  assert_true(grade_policy_valid("Optimistic"))
  assert_true(grade_policy_valid("REALISTIC"))
}

// ---------------------------------------------------------------------------
// LCG 自身性质
// ---------------------------------------------------------------------------

///|
test "lcg: 状态始终落在 31 位非负范围" {
  let mut s : Int64 = 12345L
  let mut i = 0
  while i < 2000 {
    s = lcg_next(s)
    assert_true(s >= 0L)
    assert_true(s <= 2147483647L)
    i = i + 1
  }
}

///|
test "lcg: 同种子产生同序列" {
  let a1 = lcg_next(20240101L)
  let a2 = lcg_next(20240101L)
  assert_eq(a1, a2)
  assert_eq(lcg_next(a1), lcg_next(a2))
}

///|
test "lcg: lcg_unit 落在 [0,1]" {
  let mut s : Int64 = 20240101L
  let mut i = 0
  while i < 500 {
    s = lcg_next(s)
    let u = lcg_unit(s)
    assert_true(u >= 0.0)
    assert_true(u < 1.0)
    i = i + 1
  }
}

///|
test "lcg: 不同种子产生不同序列" {
  assert_true(lcg_next(11111L) != lcg_next(99999L))
}

///|
test "lcg: 序列不是常数（不会退化）" {
  let mut s : Int64 = 42L
  let first = lcg_next(s)
  s = first
  let second = lcg_next(s)
  assert_true(first != second)
}
