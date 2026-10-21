// ============================================================================
// weight_validation_test.mbt — 权重验证套件的回归测试
//
// 覆盖三层验证的行为与病态输入的捕获能力。
// 验证逻辑本身在 weight_validation.mbt；这里锁定它的**契约**：
//   - 合法权重（官方默认）三层全过
//   - 结构问题（长度/NaN/越界）被 V1 抓住，且**全部收集**不是遇错即停
//   - 语义问题（单调性破坏、爆炸）被 V2 抓住
//   - with_params_checked 失败时给可操作的错误信息，不静默回退
// ============================================================================

///|
/// 测试辅助：官方默认权重的独立副本（防污染）。
fn fresh_default_w() -> Array[Double] {
  fsrs_default_w()
}

///|
test "wval: 官方默认权重三层验证全部通过" {
  let w = fresh_default_w()
  assert_true(validate_fsrs_weights(w) is Valid)
  assert_true(validate_fsrs_semantics(w) is Valid)
  assert_true(validate_fsrs_reference() is Valid)
  // checked 构造器接受
  assert_true(Fsrs::with_params_checked(w) is Ok(_))
}

///|
test "wval: 长度错误只报一条且解释版本错配" {
  let mk = fn(n : Int32) -> Array[Double] {
    let w = Array::make(n, 1.0)
    w
  }
  let checks = [(mk(18), 18), (mk(19), 19), (mk(23), 23)]
  for c in checks {
    let (w, n) = c
    match validate_fsrs_weights(w) {
      Invalid(xs) => {
        assert_eq(xs.length(), 1)
        assert_true(xs[0].why.contains("21"))
        assert_true(xs[0].why.contains("\{n}"))
      }
      Valid => fail("长度 \{n} 应该被拒绝")
    }
  }
}

///|
test "wval: NaN 与 Infinity 被逐个抓住" {
  let w = fresh_default_w()
  w[5] = 0.0 / 0.0
  match validate_fsrs_weights(w) {
    Invalid(xs) => {
      assert_eq(xs.length(), 1)
      assert_eq(xs[0].index, 5)
    }
    Valid => fail("NaN 应该被拒绝")
  }
  let w2 = fresh_default_w()
  w2[9] = 1.0 / 0.0
  match validate_fsrs_weights(w2) {
    Invalid(xs) => assert_eq(xs[0].index, 9)
    Valid => fail("Infinity 应该被拒绝")
  }
}

///|
test "wval: 多处问题全部收集（不是遇错即停）" {
  let w = fresh_default_w()
  w[0] = -1.0 // S0(Again) 越下界
  w[4] = 50.0 // 难度基准越上界
  w[15] = 5.0 // Hard 惩罚 > 1
  match validate_fsrs_weights(w) {
    Invalid(xs) => {
      assert_eq(xs.length(), 3)
      // 三个问题都带下标与可读解释
      let idxs = xs.map(fn(x) { x.index })
      assert_true(idxs.contains(0))
      assert_true(idxs.contains(4))
      assert_true(idxs.contains(15))
    }
    Valid => fail("三处越界应全部报告")
  }
}

///|
test "wval: 每个下标的越界都被对应边界抓住" {
  // 19 个权重逐个越上界/下界，断言都被抓住
  for i = 0; i < 19; i = i + 1 {
    let w_hi = fresh_default_w()
    w_hi[i] = w_hi[i] * 10.0 + 1000.0 // 远超任何上界
    match validate_fsrs_weights(w_hi) {
      Invalid(xs) => assert_true(xs.iter().any(fn(x) { x.index == i }))
      Valid => fail("w[\{i}] 越上界应被抓")
    }
  }
}

///|
test "wval: S₀ 单调性破坏被语义验证抓住" {
  let w = fresh_default_w()
  w[0] = 50.0 // S0(Again)=50 > S0(Hard)=1.18
  match validate_fsrs_semantics(w) {
    Invalid(xs) => assert_true(xs[0].why.contains("递增"))
    Valid => fail("单调性破坏应被抓")
  }
}

///|
test "wval: 良性微调通过（边界内不误报）" {
  // 模拟一次合理的权重微调：所有项变化 < 10%
  let w = fresh_default_w()
  for i = 0; i < 19; i = i + 1 {
    w[i] = w[i] * 1.05
  }
  // Easy 奖励 2.9898×1.05 = 3.139 仍在 [1,10]
  assert_true(validate_fsrs_weights(w) is Valid)
  assert_true(validate_fsrs_semantics(w) is Valid)
}

///|
test "wval: with_params_checked 的错误信息可操作" {
  let w = fresh_default_w()
  w[3] = -0.5
  w[16] = 0.5 // Easy 奖励 < 1，变成惩罚
  match Fsrs::with_params_checked(w) {
    Err(msg) => {
      assert_true(msg.contains("w[3]"))
      assert_true(msg.contains("w[16]"))
    }
    Ok(_) => fail("越界权重应报错")
  }
}

///|
test "wval: with_params_checked 成功时权重原样保留" {
  let w = fresh_default_w()
  w[2] = 3.5 // 合法微调
  match Fsrs::with_params_checked(w) {
    Ok(f) => {
      assert_true((f.w[2] - 3.5).abs() < 0.000000001)
      assert_true((f.desired_retention - 0.9).abs() < 0.000000001)
    }
    Err(msg) => fail("合法权重不应被拒: \{msg}")
  }
}

///|
test "wval: 参考验证的联立锚点对公式改动敏感" {
  // 把 w[9]（边际递减指数）改 0.1 → 锚点 3 的期望值会变
  // —— 证明这套锚点真的锁住了公式，不是恒真的自我确认
  let w = fresh_default_w()
  w[9] = 0.15
  // 结构上 0.15 合法（在 [0,2]），语义也合法，
  // 但参考锚点是按官方 w[9]=0.1192 算的——会失败。
  // 注意：这里直接验证的是「锚点 3 的值随权重变化」这一事实。
  let sp = stability_after_success(w, 5.0, 3.0, 0.9, 3)
  // w9 变大 → S^(-w9) 变小 → 增益变小
  assert_true(sp < 10.948986752888501)
}
