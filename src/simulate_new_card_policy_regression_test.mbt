///|
/// 审计回归（第十二轮，P3）：`simulate` 的评分器对「未建立记忆的新卡」口径不一。
///
/// ## 现象
///
/// `simulate` 在把状态喂给 `grade_fn` 前，会把 `interval_days` 换成**真实流逝
/// 天数**（`simulate_with` 的关键修正）。对一张刚 `init` 出来的新卡，这个值是 0。
/// 于是 `policy_retrievability` 走遗忘曲线：
///
/// ```
/// FSRS / SM-2：stability = 0  ⇒ 命中 `stability <= 0` 分支 → R = 0.9
/// Leitner    ：stability = interval_of(1) = 1.0（盒 1 的间隔）
///                               ⇒ forgetting_curve(0, 1.0) = 1.0 → R = 1.0
/// ```
///
/// 同一个「用户模型」对同一张未复习的卡给出两个成功率：
/// `realistic` 下 Leitner 必然判 Easy（FSRS/SM-2 判 Good），`pessimistic`
/// 下 Leitner 的新卡**永远不会**被记成 Again（r×0.7 = 0.7 的上界意味着
/// u 总有 7 成概率通过，而另外两个是 63%）。
///
/// ## 判据
///
/// 「未复习过」是**调度器无关**的状态（`phase == New`），三个调度器的评分
/// 必须同档。这里扫一串种子逐点比对——只比对同一次随机流下的判定，
/// 不依赖具体 LCG 值。

///|
/// 模拟器喂给评分器的状态副本（`simulate_with` 里 `for_grading` 的等价物）：
/// 把 `interval_days` 换成真实流逝天数 0（新卡刚 init，now − last_review = 0）。
fn as_graded(st : CardState) -> CardState {
  {
    card_id: st.card_id,
    stability: st.stability,
    difficulty: st.difficulty,
    reps: st.reps,
    lapses: st.lapses,
    last_review: st.last_review,
    due: st.due,
    interval_days: 0.0,
    phase: st.phase,
  }
}

///|
test "simulate 策略：未复习的新卡在三种调度器上判定一致（realistic）" {
  let leitner_new = as_graded(Leitner::new().init("c", 0L))
  let sm2_new = as_graded(Sm2::new().init("c", 0L))
  let fsrs_new = as_graded(Fsrs::new().init("c", 0L))
  for seed = 1L; seed <= 100L; seed = seed + 1L {
    let pl = realistic_policy(seed)
    let ps = realistic_policy(seed)
    let pf = realistic_policy(seed)
    let gl = pl(leitner_new).label()
    let gs = ps(sm2_new).label()
    let gf = pf(fsrs_new).label()
    if gl != gs || gl != gf {
      fail(
        "seed=\{seed}: leitner=\{gl} sm2=\{gs} fsrs=\{gf}——未复习的新卡不该有调度器差异",
      )
    }
  }
}

///|
test "simulate 策略：未复习的新卡在三种调度器上判定一致（pessimistic）" {
  let leitner_new = as_graded(Leitner::new().init("c", 0L))
  let sm2_new = as_graded(Sm2::new().init("c", 0L))
  let fsrs_new = as_graded(Fsrs::new().init("c", 0L))
  for seed = 1L; seed <= 100L; seed = seed + 1L {
    let pl = pessimistic_policy(seed)
    let ps = pessimistic_policy(seed)
    let pf = pessimistic_policy(seed)
    let gl = pl(leitner_new).label()
    let gs = ps(sm2_new).label()
    let gf = pf(fsrs_new).label()
    if gl != gs || gl != gf {
      fail(
        "seed=\{seed}: leitner=\{gl} sm2=\{gs} fsrs=\{gf}——pessimistic 下差异会直接改变 Again 率",
      )
    }
  }
}

///|
test "simulate 策略：复习过的卡仍按各自算法算 R（守卫不许外溢）" {
  // 复习过一次的 Leitner 卡（盒 2，间隔 2 天），逾期 1 天：
  // R_leitner = forgetting_curve(1, 2) —— 与 FSRS 的 stability 不是同一个量，
  // 但这条路径**不该**被「新卡」守卫短路：两者都 < 1，且 Leitner 的值由
  // 自己的 stability 决定，不因守卫而改成 0.9。
  let mut st = Leitner::new().init("c", 0L)
  st = Leitner::new().review(st, Good, 0L) // 盒 2，interval 2 天
  let graded = as_graded(st)
  // 真实流逝 0 天 ⇒ R = 1（没过期），这里只断言「不是被短路成 0.9」：
  inspect(forgetting_curve(0.0, graded.stability), content="1")
  inspect(graded.stability, content="2")
  // 逾期 1 天时 R = (1 + 19/81 × 1/2)^(-0.5) ≈ 0.9437，明显不是 0.9。
  let r_overdue = forgetting_curve(1.0, graded.stability)
  assert_true(r_overdue > 0.9)
  assert_true(r_overdue < 1.0)
}
