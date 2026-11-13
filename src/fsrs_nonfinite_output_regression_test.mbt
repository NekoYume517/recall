// ============================================================================
// 非有限**输出**：有限权重把 stability 推成 Infinity（2026-11-13 审计 D3）
//
// ## 承诺
//
// `API.md` §3.2 与 `src/fsrs.mbt` 的 R-6 注释一起声明：`with_params` 容忍
// 非有限权重，但「底层稳定性仍有 0.1 下限保护」。R-6 修的是**输入侧**
// （S 与 w 的非有限值落到 0.1）。这条修的是**输出侧**：
// `stability_after_success` / `stability_after_lapse` 收尾判断写的是
//
//     if next.is_nan() || next < 0.1 { 0.1 } else { next }
//
// 只挡 NaN —— `+Inf` 既不 is_nan，也不 `< 0.1`，于是**原样成为 `CardState.stability`**。
// 而同一族里 `step` 的短期分支写的是 `!is_finite(raw) || raw < 0.1`（R-6 改的），
// 对同一类输入落 0.1：同一个调度器在两条分支上对「非有限结果」给出相反处置。
//
// ## 实测（修复前，`fsrs_default_w()` 只改一项）
//
//     stability_after_success(w[8]=1e308,  D=5, S=3, R=0.9)  = Infinity
//     stability_after_success(w[16]=1e308, D=5, S=3, R=0.9, Easy) = Infinity
//     stability_after_lapse  (w[11]=w[14]=1e308, w[17]=1e308, w[18]=-1e308) = Infinity
//     Fsrs::with_params(w[8]=1e308) → 第 2 次 review(Good) → stability=Infinity, iv=36500
//
// 后果：`retrievability` 恒为 1（S=Inf ⇒ 永不遗忘），`interval_days` 恒 36500
// （100 年上限），`export_anki_tsv` 把 `Infinity` 写进 stability 列。
// 这些权重是 `with_params` 明文档化的合法输入（它「不校验有限性、范围」）。
// ============================================================================

///|
fn d3_w(idx : Int32, value : Double) -> Array[Double] {
  let w = fsrs_default_w()
  w[idx] = value
  w
}

///|
fn d3_finite(x : Double) -> Bool {
  !x.is_nan() && x != 1.0 / 0.0 && x != -1.0 / 0.0
}

///|
test "D3: 成功路径的极端有限权重不再产出 Infinity（落 0.1 下限）" {
  // w[8] 是 exp 前的整体缩放：exp(1e308) = +Inf ⇒ gain = +Inf ⇒ S' = +Inf
  let s = stability_after_success(d3_w(8, 1.0e308), 5.0, 3.0, 0.9, 3)
  assert_true(d3_finite(s))
  inspect(s, content="0.1")
  // w[16] 是 Easy 奖励因子，只在 g==4 乘入
  let s_easy = stability_after_success(d3_w(16, 1.0e308), 5.0, 3.0, 0.9, 4)
  assert_true(d3_finite(s_easy))
  inspect(s_easy, content="0.1")
}

///|
test "D3: 遗忘路径的极端有限权重不再产出 Infinity（落 0.1 下限）" {
  // w[11]/w[14] 把长项推到 +Inf，同时 w[17]·w[18] = -Inf 让短期上限
  // `S / exp(w17·w18)` 也变成 +Inf（上限失效），两条路都兜不住
  let w = d3_w(11, 1.0e308)
  w[14] = 1.0e308
  w[17] = 1.0e308
  w[18] = -1.0e308
  let s = stability_after_lapse(w, 5.0, 3.0, 0.5)
  assert_true(d3_finite(s))
  inspect(s, content="0.1")
}

///|
test "D3: 端到端——with_params(1e308) 不再把 Infinity 写进 CardState" {
  let f = Fsrs::with_params(d3_w(8, 1.0e308))
  let c0 = Scheduler::init(f, "c", 0L)
  let c1 = Scheduler::review(f, c0, Good, 0L)
  assert_true(d3_finite(c1.stability))
  // 第 2 次走长期成功路径（elapsed = 1 天）
  let c2 = Scheduler::review(f, c1, Good, 86400L)
  assert_true(d3_finite(c2.stability))
  assert_true(d3_finite(c2.interval_days))
  assert_true(c2.interval_days >= 1.0 && c2.interval_days <= 36500.0)
  // S 不再是 Infinity ⇒ R 不再被钉在 1
  let r = Scheduler::retrievability(f, c2, 864000L)
  assert_true(r >= 0.0 && r <= 1.0)
  assert_true(r < 1.0)
  // 同日重复评分（短期分支）同样有限——它与长期路径此刻处置一致
  let c3 = Scheduler::review(f, c2, Good, 86400L + 3600L)
  assert_true(d3_finite(c3.stability))
}

///|
test "D3: 合法权重与有限大值的输出逐位不变（防过度收紧）" {
  let w = fsrs_default_w()
  // py-fsrs 5.1.3 的两条官方锚点（validate_fsrs_reference 里也锁着）
  let sp = stability_after_success(w, 5.0, 3.0, 0.9, 3)
  assert_true((sp - 10.948986752888501).abs() < 0.000000001)
  let sl = stability_after_lapse(w, 5.0, 3.0, 0.5)
  assert_true((sl - 2.1310280879406296).abs() < 0.000000001)
  // 有限但巨大的结果**不动**：只挡非有限
  let big = stability_after_lapse(d3_w(11, 1.0e308), 5.0, 3.0, 0.5)
  assert_true(d3_finite(big))
  assert_true(big > 1.0)
  inspect(big, content="2.1310280879406296")
}
