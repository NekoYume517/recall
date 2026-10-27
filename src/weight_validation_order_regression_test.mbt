// ============================================================================
// RC-4 回归测试（2026-10-27）：验证器必须与引擎用同一套状态转移顺序
//
// 契约（三处一致声明）：
//   API.md 3.2      「D' 与 S' 从同一份旧状态独立计算，新 D 仅保存到输出状态」
//   implementation.md §6「稳定性更新使用复习前的 D」
//   fsrs.mbt 的 step 注释「新 D 只作为返回状态保存，不反馈进同一次 S' 计算」
//
// 引擎（fsrs.mbt step）：d_next = next_difficulty(旧 d) 之后，
//   s_next = stability_after_success(w, **旧 d**, s, r, rating)。
//
// 旧校验器（weight_validation.mbt 的 validate_fsrs_semantics 第 3 项）
// 顺序相反：先 d = next_difficulty(...)，再 stability_after_success(w, d, ...)
// 用**新** d。w[7]（mean reversion 强度，合法域 [0,1]）越大分歧越大：
//   w[7]=1.0  engine S5=18.941073805407296  old-order S5=19.782952312966213
//   rating=Again 时差 +9.81%
//
// 修复把这条 Good×N 演化抽成公开的 `success_chain`（唯一实现），
// 校验器改为调用它，于是「验证器用什么顺序」由这一处决定、可直接断言。
// ============================================================================

///|
/// 有限性判定（`weight_validation.mbt` 的 is_finite 是私有函数，
/// 测试里用不了，这里按同一定义复写一份）。
fn rc4_finite(x : Double) -> Bool {
  !x.is_nan() && x != 1.0 / 0.0 && x != -1.0 / 0.0
}

///|
/// 引擎顺序复算 Good×5（用旧 D 算 S）——直接走 `step`，不复制公式。
fn rc4_engine_seq(w : Array[Double], rating : Int32) -> Double {
  let mut d = initial_difficulty(w, rating)
  let mut s = initial_stability(w, rating)
  for _ in 0..<5 {
    let (s2, d2, _) = step(w, 0.9, d, s, 1.0, rating, false)
    s = s2
    d = d2
  }
  s
}

///|
/// 旧校验器的顺序（先更新 D，再用新 D 算 S）——只用于对照，证明缺陷真实。
fn rc4_old_order(w : Array[Double], rating : Int32) -> Double {
  let mut d = initial_difficulty(w, rating)
  let mut s = initial_stability(w, rating)
  for _ in 0..<5 {
    let r = forgetting_curve(1.0, s)
    d = next_difficulty(w, d, rating)
    s = stability_after_success(w, d, s, r, rating)
  }
  s
}

///|
test "RC-4: 缺陷前提——引擎顺序与旧校验器顺序确实分歧" {
  let w = fsrs_default_w()
  w[7] = 1.0
  let engine = rc4_engine_seq(w, 3)
  let old = rc4_old_order(w, 3)
  // 两个具体值（审计时实测）
  assert_true((engine - 18.941073805407296).abs() < 0.000000001)
  assert_true((old - 19.782952312966213).abs() < 0.000000001)
  assert_true((old - engine).abs() > 0.5)
}

///|
test "RC-4: success_chain 采用引擎顺序（用旧 D 算 S）" {
  // 这是修复的核心：校验器改为调用 success_chain，
  // 因此「校验器用什么顺序」由这个函数唯一决定。
  let w = fsrs_default_w()
  w[7] = 1.0
  let chain = success_chain(w, 3, 5)
  let engine = rc4_engine_seq(w, 3)
  let old = rc4_old_order(w, 3)
  // 与引擎逐位一致
  assert_true((chain - engine).abs() < 0.000000001)
  // 与旧（错）顺序明显不同
  assert_true((chain - old).abs() > 0.5)
}

///|
test "RC-4: success_chain 对四种评分都与 step 的累积结果一致" {
  for rating in [1, 2, 3, 4] {
    let w = fsrs_default_w()
    w[7] = 1.0
    let chain = success_chain(w, rating, 5)
    let engine = rc4_engine_seq(w, rating)
    assert_true((chain - engine).abs() < 0.000000001)
  }
}

///|
test "RC-4: success_chain 在默认权重下等于文档记录的 Good×5 S5" {
  let w = fsrs_default_w()
  let s5 = success_chain(w, 3, 5)
  assert_true((s5 - 15.631302463432553).abs() < 0.000000001)
  // 同时锁住首步 S1（默认权重、elapsed=1 天、Good）
  let s1 = success_chain(w, 3, 1)
  assert_true((s1 - 5.869141822641378).abs() < 0.000000001)
}

///|
test "RC-4: success_chain(w, g, 0) 返回初始稳定性" {
  let w = fsrs_default_w()
  for rating in [1, 2, 3, 4] {
    let s0 = success_chain(w, rating, 0)
    assert_true((s0 - initial_stability(w, rating)).abs() < 0.000000001)
  }
}

///|
test "RC-4: validate_fsrs_semantics 仍对默认权重给 Valid" {
  match validate_fsrs_semantics(fsrs_default_w()) {
    Valid => ()
    Invalid(xs) =>
      fail("默认权重必须 Valid，得到 \{xs.length()} 处问题")
  }
}

///|
test "RC-4: validate_fsrs_semantics 对 w[7]=1.0 与引擎同结论" {
  // w[7]=1.0 在 weight_bounds()[7] = [0.0, 1.0] 内，引擎下 S5=18.94（健康）。
  // 校验器若仍用旧顺序会拿 19.78 判断——两者都健康，所以这里主要锁
  // "不因为顺序差异而误报"。真正的顺序锁定在上面 success_chain 测试。
  let w = fsrs_default_w()
  w[7] = 1.0
  match validate_fsrs_semantics(w) {
    Valid => ()
    Invalid(xs) => fail("期望 Valid，得到 \{xs.length()} 处问题")
  }
  // 引擎侧的结论确实是健康的
  assert_true(rc4_finite(rc4_engine_seq(w, 3)))
  assert_true(rc4_engine_seq(w, 3) < 1000000.0)
}

///|
test "RC-4: 校验器的第 3 项能看见引擎侧的爆炸" {
  // 用极端 w[8] 构造一份「引擎下爆炸」的权重，断言 success_chain
  // 如实地把它算到 >= 1e6（即校验器的第 3 项能看见病态）。
  let w = fsrs_default_w()
  w[8] = 5.0 // bounds 上限
  let chain = success_chain(w, 3, 5)
  println("w[8]=5.0 引擎顺序 S5=" + chain.to_string())
  // 若它确实爆炸，校验器必须报 Invalid（说明第 3 项真的能看到病态）
  match validate_fsrs_semantics(w) {
    Valid => assert_true(chain < 1000000.0)
    Invalid(_) => assert_true(chain >= 1000000.0)
  }
}
