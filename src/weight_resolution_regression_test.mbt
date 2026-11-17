///|
/// 审计回归（第十二轮，P3）：`validate_fsrs_semantics` 的第五个不变量。
///
/// ## 现象
///
/// `weight_validation.mbt` 的注释从第一版起就把「难度恒为 1」列为要拦的语义
/// 病态，但它列的四个不变量（S₀ 单调 / 有限性 / Good×5 不爆炸 / 间隔敏感性）
/// 都不检查它。构造一份**全部落在 `weight_bounds` 内**的权重就能通过：
///
/// ```
/// w[4] = 1.0   // 难度基准 = 下限
/// w[5] = 0.0   // 评分敏感度 0 ⇒ D₀(g) = 1 - exp(0) + 1 = 1 对任意 g
/// w[6] = 0.0   // 难度增量 0 ⇒ D' ≡ 1
/// ```
///
/// 于是 `with_params_checked` 返回 **Ok**，给一份「难度完全失去分辨率」的权重
/// 背书——而 `docs/implementation.md` §4 把它记成真 bug：难度没有分辨率 ⇒
/// `(11 - D)` 恒为 10 ⇒ **系统性高估间隔增长**（难卡被误判成「已经记牢」）。

///|
/// 难度恒为 1 的病态权重（结构层全部合法）。
fn flat_difficulty_weights() -> Array[Double] {
  let w = fsrs_default_w()
  w[4] = 1.0
  w[5] = 0.0
  w[6] = 0.0
  w
}

///|
test "语义校验：难度恒为 1 的权重必须被拒（结构层仍然合法）" {
  let w = flat_difficulty_weights()
  // 前提：结构层（长度/有限性/逐项范围）必须仍然通过，否则测的不是语义层。
  match validate_fsrs_weights(w) {
    Valid => ()
    Invalid(_) => fail("结构层不该拒这份权重（bounds 内）")
  }
  // D₀ 确实恒定：这是缺陷的形态本身。
  inspect(initial_difficulty(w, 1), content="1")
  inspect(initial_difficulty(w, 4), content="1")
  // 语义层必须拒，并给出「D₀ 必须随评分递减」这一条。
  match validate_fsrs_semantics(w) {
    Valid => fail("难度恒为 1 的病态权重不该通过语义校验")
    Invalid(issues) => {
      let mut found = false
      for x in issues {
        if x.why.contains("D₀ 必须随评分递减") {
          found = true
        }
      }
      assert_true(found)
    }
  }
  // 严格版构造器随之报错（不再给病态权重背书）。
  match Fsrs::with_params_checked(w) {
    Ok(_) => fail("with_params_checked 不该接受难度恒定的权重")
    Err(msg) => assert_true(msg.contains("语义病态"))
  }
}

///|
test "语义校验：默认权重与「敏感度很小但非零」的权重仍然放行（防过度收紧）" {
  // 官方默认：D₀(1) = 7.1949 > D₀(4) = 3.2245 —— 必须 Valid（V3 锚点依赖它）。
  match validate_fsrs_semantics(fsrs_default_w()) {
    Valid => ()
    Invalid(_) => fail("官方默认权重必须通过语义校验")
  }
  match validate_fsrs_reference() {
    Valid => ()
    Invalid(_) => fail("V3 参考锚点必须成立")
  }
  // 敏感度压到 0.01（仍在 bounds 的 [0,5] 内）：D₀ 之差约 3e-4，仍严格递减。
  let w = fsrs_default_w()
  w[5] = 0.01
  assert_true(initial_difficulty(w, 1) > initial_difficulty(w, 4))
  match validate_fsrs_semantics(w) {
    Valid => ()
    Invalid(issues) => {
      let mut bad = false
      for x in issues {
        if x.why.contains("D₀ 必须随评分递减") {
          bad = true
        }
      }
      if bad {
        fail(
          "敏感度 0.01 仍让 D₀ 严格递减，不该被这条判据拒",
        )
      }
    }
  }
}
