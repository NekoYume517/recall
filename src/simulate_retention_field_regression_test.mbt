// ============================================================================
// RC-3 回归测试（2026-10-27）：`SimConfig.desired_retention` 必须真正生效
//
// 现象：旧实现里这个字段**没有任何读取点**。两个只差该字段的 SimConfig
// 输出逐字段相同：
//   0.9 → total=480  final_backlog=1164
//   0.7 → total=480  final_backlog=1164
// 而换成 `Fsrs::with_retention(0.7)` 的实例才是 1089 —— 说明字段被忽略，
// 目标保持率只能靠调用方自己换调度器实例。
//
// 契约：simulate.mbt 的字段注释写「目标保持率（透传给调度器构造）」，
// API.md 5 节把它列为 SimConfig 的公开字段，AdviceRequest::to_config
// 每次都填它。声明为「透传」就必须真的影响结果。
//
// 语义按调度器分派（与 CLI `--retention` 一致）：
//   - Fsrs：desired_retention 是一等参数，间隔由它反解 → 必须生效
//   - Sm2 / Leitner：算法本身没有这个参数（desired_retention() 返回固定
//     0.9 / 1.0）→ 字段对它们无效，两次跑出相同结果，且文档写明
// ============================================================================

///|
/// 造一个只差 desired_retention 的配置（其余逐字段相同）。
fn rc3_config(r : Double) -> SimConfig {
  {
    days: 60,
    new_per_day: 20,
    review_limit: 8,
    desired_retention: r,
    grade_fn: grade_policy_with_seed("realistic", 20240101L),
    seed: 20240101L,
  }
}

///|
test "RC-3: AnyScheduler::with_retention 只对 Fsrs 生效" {
  // Fsrs：换目标保持率
  let f = AnyScheduler::with_retention(AnyScheduler::Fsrs(Fsrs::new()), 0.7)
  match f {
    Fsrs(s) => assert_true((s.desired_retention - 0.7).abs() < 0.000000001)
    _ => fail("期望仍是 Fsrs 变体")
  }
  // Sm2：没有这个参数，原样返回
  let m = AnyScheduler::with_retention(AnyScheduler::Sm2(Sm2::new()), 0.7)
  match m {
    Sm2(s) => assert_true((s.ease_factor - 2.5).abs() < 0.000000001)
    _ => fail("期望仍是 Sm2 变体")
  }
  // Leitner：同上
  let l = AnyScheduler::with_retention(
    AnyScheduler::Leitner(Leitner::new()),
    0.7,
  )
  match l {
    Leitner(s) => assert_eq(s.boxes, 5)
    _ => fail("期望仍是 Leitner 变体")
  }
}

///|
test "RC-3: Fsrs 下 SimConfig.desired_retention 0.9 与 0.7 结果必须不同" {
  let a = simulate(AnyScheduler::Fsrs(Fsrs::new()), rc3_config(0.9))
  let b = simulate(AnyScheduler::Fsrs(Fsrs::new()), rc3_config(0.7))
  // 0.7 目标 → 间隔更长 → 到期更少 → 复习更少、积压更小
  assert_true(
    a.total_reviews != b.total_reviews || a.final_backlog != b.final_backlog,
  )
  assert_true(b.final_backlog <= a.final_backlog)
}

///|
test "RC-3: 配置字段与显式 with_retention(0.7) 实例给出同一结果" {
  // 这是脚本里最容易出现的等价写法，必须一致：
  //   simulate(Fsrs::with_retention(0.7), cfg{retention:0.7})
  //   == simulate(Fsrs::new(),               cfg{retention:0.7})
  let via_field = simulate(AnyScheduler::Fsrs(Fsrs::new()), rc3_config(0.7))
  let via_instance = simulate(
    AnyScheduler::Fsrs(Fsrs::with_retention(0.7)),
    rc3_config(0.7),
  )
  assert_eq(via_field.total_reviews, via_instance.total_reviews)
  assert_eq(via_field.final_backlog, via_instance.final_backlog)
}

///|
test "RC-3: 配置字段的 0.7 与旧已知值 1089 吻合（不再是 1164）" {
  // 审计记录：Fsrs::with_retention(0.7) 在同一配置下 final_backlog = 1089，
  // 而被忽略的字段路径给出 1164。修复后字段路径必须落到 1089。
  let via_field = simulate(AnyScheduler::Fsrs(Fsrs::new()), rc3_config(0.7))
  assert_eq(via_field.final_backlog, 1089)
  let r90 = simulate(AnyScheduler::Fsrs(Fsrs::new()), rc3_config(0.9))
  assert_eq(r90.final_backlog, 1164)
}

///|
test "RC-3: Sm2 下该字段无效（算法局限），两次结果相同且与文档一致" {
  // SM-2 的 desired_retention() 固定 0.9，没有可调旋钮
  let a = simulate(AnyScheduler::Sm2(Sm2::new()), rc3_config(0.9))
  let b = simulate(AnyScheduler::Sm2(Sm2::new()), rc3_config(0.7))
  assert_eq(a.total_reviews, b.total_reviews)
  assert_eq(a.final_backlog, b.final_backlog)
  // 顺带锁住：SM-2 实例的目标保持率确实是固定 0.9
  assert_true((Sm2::new().desired_retention() - 0.9).abs() < 0.000000001)
}

///|
test "RC-3: Leitner 下该字段无效，两次结果相同" {
  let a = simulate(AnyScheduler::Leitner(Leitner::new()), rc3_config(0.9))
  let b = simulate(AnyScheduler::Leitner(Leitner::new()), rc3_config(0.7))
  assert_eq(a.total_reviews, b.total_reviews)
  assert_eq(a.final_backlog, b.final_backlog)
  assert_true((Leitner::new().desired_retention() - 1.0).abs() < 0.000000001)
}

///|
test "RC-3: 泛型 simulate_with 不改调度器——语义由 simulate 承担" {
  // MoonBit 的 trait 不支持默认实现，泛型 `[T : Scheduler]` 入口拿不到
  // 实例重建能力（也就无法把配置里的目标保持率施加到任意 T 上）。
  // 因此约定并锁定：**`simulate_with` 按传入实例原样跑**，
  // 目标保持率的透传由 `simulate`（AnyScheduler 入口，CLI 与 advice
  // 都走它）负责。这条测试防止有人误以为泛型入口也会改 retention。
  let a = simulate_with(Fsrs::new(), rc3_config(0.9))
  let b = simulate_with(Fsrs::new(), rc3_config(0.7))
  // 同一实例 + 只差配置字段 → 泛型入口给出相同结果（实例说了算）
  assert_eq(a.final_backlog, b.final_backlog)
  assert_eq(a.final_backlog, 1164)
  // 想让它生效，就把 retention 施加到实例上再传进来
  let c = simulate_with(Fsrs::with_retention(0.7), rc3_config(0.7))
  assert_eq(c.final_backlog, 1089)
}

///|
test "RC-3: simulate 入口（CLI / advice 走的那条）真正透传配置字段" {
  let a = simulate(AnyScheduler::Fsrs(Fsrs::new()), rc3_config(0.9))
  let b = simulate(AnyScheduler::Fsrs(Fsrs::new()), rc3_config(0.7))
  assert_true(a.final_backlog != b.final_backlog)
  assert_eq(a.final_backlog, 1164)
  assert_eq(b.final_backlog, 1089)
}

///|
test "RC-3: 目标保持率越界时按 Fsrs::with_retention 的边界夹取" {
  // 0.3 会被夹到 0.5、1.0 回退 0.9 —— 与 CLI 的 effective_retention
  // 同一套决策（clamp_retention 单点实现），两处必须一致。
  let clipped = simulate(AnyScheduler::Fsrs(Fsrs::new()), rc3_config(0.3))
  let explicit = simulate(
    AnyScheduler::Fsrs(Fsrs::with_retention(0.5)),
    rc3_config(0.3),
  )
  assert_eq(clipped.final_backlog, explicit.final_backlog)
  let fallback = simulate(AnyScheduler::Fsrs(Fsrs::new()), rc3_config(1.0))
  let base = simulate(AnyScheduler::Fsrs(Fsrs::new()), rc3_config(0.9))
  assert_eq(fallback.final_backlog, base.final_backlog)
  // 边界本身
  assert_true((clamp_retention(0.3) - 0.5).abs() < 0.000000001)
  assert_true((clamp_retention(1.0) - 0.9).abs() < 0.000000001)
  assert_true((clamp_retention(0.995) - 0.99).abs() < 0.000000001)
}

///|
test "RC-3: AnyScheduler::with_retention 保留自备权重" {
  // 用非默认权重构造，再改目标保持率，权重不能被重置成官方默认
  let custom = fsrs_default_w()
  custom[0] = 0.9 // S0(Again) 0.40255 → 0.9
  let base = Fsrs::with_params(custom)
  let rebuilt = AnyScheduler::with_retention(AnyScheduler::Fsrs(base), 0.7)
  match rebuilt {
    Fsrs(s) => {
      assert_true((s.desired_retention - 0.7).abs() < 0.000000001)
      // 权重仍然是自备的那份
      assert_true((s.weights()[0] - 0.9).abs() < 0.000000001)
    }
    _ => fail("期望 Fsrs 变体")
  }
}

///|
test "RC-3: AdviceRequest 的 desired_retention 经 to_config 传到模拟" {
  let req : AdviceRequest = {
    days: 40,
    review_limit: 10,
    desired_retention: 0.7,
    policy_factory: fn() { grade_policy_with_seed("realistic", 20240101L) },
    seed: 20240101L,
    target_backlog: 0,
  }
  let cfg70 = req.to_config(10)
  assert_eq(cfg70.desired_retention, 0.7)
  // 同速率下 0.7 与 0.9 目标的模拟必须不同
  let sim70 = simulate(AnyScheduler::Fsrs(Fsrs::new()), cfg70)
  let sim90 = simulate(AnyScheduler::Fsrs(Fsrs::new()), {
    ..cfg70,
    desired_retention: 0.9,
  })
  assert_true(
    sim70.total_reviews != sim90.total_reviews ||
    sim70.final_backlog != sim90.final_backlog,
  )
}
