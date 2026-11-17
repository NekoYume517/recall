///|
/// 审计回归（第十三轮，P3）：`next_difficulty` / `success_chain` 没有夹 `rating`。
///
/// ## 现象
///
/// `rating`（FSRS 的 1..4 评分刻度）在四个公开公式入口上出现：
///
/// ```
/// initial_stability(w, rating)    ← 夹了（第十二轮 89304e9 的 clamp_rating）
/// initial_difficulty(w, rating)   ← 夹了
/// next_difficulty(w, d, rating)   ← 没夹
/// success_chain(w, rating, steps) ← 没夹
/// ```
///
/// 于是同一个越界 `rating` 在「初始状态」上按 1 或 4 处理，在「难度推进」
/// 上却按原值算：
///
/// ```
/// next_difficulty(w, 5.0, 0)  = 7.414636307311108   （按 g=0 算，比 Again 还难）
/// next_difficulty(w, 5.0, 1)  = 6.607035107311108   （按 g=1 = Again）
/// next_difficulty(w, 5.0, 5)  = 3.376630307311108   （按 g=5 算，越界）
/// ```
///
/// ## 根因
///
/// 第十二轮把「rating ∈ 1..4 这个前置条件只定义一处」写成了 `clamp_rating`，
/// 但只接到两处 `initial_*`。`API.md` §3.2 的难度更新公式写的是
/// `delta_D = -w[6] · (g − 3) · (10 − D) / 9`，`g ∈ 1..4`——`next_difficulty`
/// 是同一个定义域的第三个入口，漏了同一份夹取。
///
/// ## 判级理由
///
/// P3，与第十二轮 R12-5（`initial_difficulty(w,0) ≠ initial_difficulty(w,1)`）
/// 同型同族：调度器路径由 `fsrs_rating` 保证 1..4，不可达；但这是公开公式
/// 入口，库级直接调用（自备权重实验、外部状态修复）会拿到域外语义，
/// 且与同族两个函数口径不一致。

///|
test "R13-3: next_difficulty 的 rating 与两处 initial_* 同口径（夹到 1..4）" {
  let w = fsrs_default_w()
  let d = 5.0
  // 下界：0 与负值按 1（Again）处理。
  assert_true(next_difficulty(w, d, 0) == next_difficulty(w, d, 1))
  assert_true(next_difficulty(w, d, -3) == next_difficulty(w, d, 1))
  // 上界：5 及以上按 4（Easy）处理。
  assert_true(next_difficulty(w, d, 5) == next_difficulty(w, d, 4))
  assert_true(next_difficulty(w, d, 99) == next_difficulty(w, d, 4))
}

///|
test "R13-3: success_chain 的 rating 同样只在定义域内取值" {
  let w = fsrs_default_w()
  assert_true(success_chain(w, 0, 3) == success_chain(w, 1, 3))
  assert_true(success_chain(w, 5, 3) == success_chain(w, 4, 3))
  assert_true(success_chain(w, -1, 2) == success_chain(w, 1, 2))
}

///|
test "R13-3: 域内 rating 的推进逐位不变（防过度收紧）" {
  let w = fsrs_default_w()
  let d = 5.0
  inspect(next_difficulty(w, d, 1), content="6.607035107311108")
  inspect(next_difficulty(w, d, 2), content="5.7994339073111085")
  inspect(next_difficulty(w, d, 3), content="4.991832707311108")
  inspect(next_difficulty(w, d, 4), content="4.184231507311108")
  // 默认权重下 Good×5 / Good×3 的稳定性链（既有锚点，不能被这条修复改动）。
  assert_true(approx_default(success_chain(w, 3, 5), 15.631302463432553))
  assert_true(approx_default(success_chain(w, 3, 3), 10.881586135746016))
}

///|
test "R13-3: 调度器路径（step / review）不受影响" {
  // `fsrs_rating` 只产出 1..4，因此夹取是恒等变换：同一次复习的
  // (S, D, interval) 三元组必须逐位不变。
  let w = fsrs_default_w()
  let (s, dd, iv) = step(w, 0.9, 5.0, 10.0, 3.0, 3, false)
  assert_true(
    approx_default(
      s,
      stability_after_success(w, 5.0, 10.0, forgetting_curve(3.0, 10.0), 3),
    ),
  )
  assert_true(approx_default(dd, next_difficulty(w, 5.0, 3)))
  assert_true(approx_default(iv, interval_days(s, 0.9)))
}
