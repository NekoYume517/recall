// ============================================================================
// SM-2 外部状态的 EF 守卫：NaN 穿过 `< 1.3`（2026-11-13 审计 D2）
//
// ## 承诺
//
// `src/sm2.mbt` 的 `impl Scheduler for Sm2` 里写着一条明确的「外来状态防御」：
//
//   > 外来状态防御：difficulty 是 pub(all) 字段，调用方可能构造（或从旧数据
//   > 恢复出）低于下限的值。此时夹到 sm2_min_ease()——尊重"这张卡 EF 很低"
//   > 的事实按 1.3 继续。
//
// `sm2_next_interval` 的契约同样是「夹到 [1, 36500]」，`sm2_next_ease`
// 写着「带 1.3 下限」。可这三处的写法都是**比较式**（`x < 1.3`），
// 而 `NaN < 1.3` 为 false —— NaN 从这三条守卫中间穿过去，
// 于是 EF 一旦是 NaN 就永远是 NaN。
//
// ## 实测（修复前）
//
// CardState 是 `pub(all)`、`Timestamp`/字段都可直接构造，库级可达
// （与 R-6 / RC-7 / N-2 的可达性论证同型）。把 EF 置成 NaN 后连做三次 Good：
//
//     difficulty=NaN  iv1=1  iv3=1     ← 修复前：间隔永久塌在 1 天
//     difficulty=NaN  iv1=1  iv3=8     ← 修复后（按 1.3 继续）
//
// `sm2_next_interval` 第 3 次起算 `round(prev_interval * ease)`，
// `ease` 是 NaN → `round(NaN)` = NaN → 落到 1 天下限。也就是说：
// **EF 非有限 ⇒ 这张卡从此每天到期一次**（`due` 恒为 now+1 天），
// 而 `replay` 只会在表格里打一个 `NaN`，没有任何告警。
//
// ## 为什么是缺陷而不是"调用方责任"
//
// 同族先例（R-6，2026-11-12）：`Fsrs::with_params` 明文接受非有限权重，
// 因此**下游公式必须自己守住不变量**。SM-2 这一侧的对应承诺就是上面那句
// 「外来状态防御」+「EF 下限 1.3」——守卫已经在写了，只是漏了 NaN。
// 与 `stabilities` 系一致：比较式守卫必须显式处理 NaN。
// ============================================================================

///|
fn d2_review_chain(sm : Sm2, difficulty : Double) -> CardState {
  let base = Scheduler::init(sm, "c", 0L)
  let start = { ..base, difficulty, }
  let r1 = Scheduler::review(sm, start, Good, 0L)
  let r2 = Scheduler::review(sm, r1, Good, 86400L)
  Scheduler::review(sm, r2, Good, 172800L)
}

///|
test "D2: 外部状态的 EF 是 NaN 时按 1.3 下限继续（不是死循环在 1 天）" {
  let r = d2_review_chain(Sm2::new(), 0.0 / 0.0)
  assert_false(r.difficulty.is_nan())
  inspect(r.difficulty, content="1.3")
  // 与「EF 本来就在下限」的合法路径逐位一致：1 → 6 → round(6×1.3)=8
  let legit = d2_review_chain(Sm2::new(), 1.3)
  inspect(r.interval_days, content="8")
  inspect(r.interval_days == legit.interval_days, content="true")
}

///|
test "D2: 外部状态的 EF 是 ±Inf 时同样按下限继续" {
  let pos = d2_review_chain(Sm2::new(), 1.0 / 0.0)
  assert_false(pos.difficulty == 1.0 / 0.0)
  inspect(pos.difficulty, content="1.3")
  let neg = d2_review_chain(Sm2::new(), -1.0 / 0.0)
  inspect(neg.difficulty, content="1.3")
  inspect(neg.interval_days, content="8")
}

///|
test "D2: with_ease(NaN) 自身的「夹到 1.3」承诺也成立" {
  let sm = Sm2::with_ease(0.0 / 0.0)
  assert_false(sm.ease_factor.is_nan())
  inspect(sm.ease_factor, content="1.3")
  // init 写进 CardState 的 EF 镜像也不能是 NaN
  let st = Scheduler::init(sm, "c", 0L)
  assert_false(st.difficulty.is_nan())
  // 底线：EF 永远不会变成非有限值（哪怕输入是非有限值）
  let a = sm2_next_ease(2.5, Good)
  inspect(a, content="2.5")
  let b = sm2_next_ease(1.0 / 0.0, Good)
  assert_false(b == 1.0 / 0.0)
  let c = sm2_next_ease(0.0 / 0.0, Again)
  assert_false(c.is_nan())
  inspect(c, content="1.3")
}

///|
test "D2: 合法外部状态（>= 1.3）的行为逐位不变" {
  for ease in [1.3, 1.5, 2.5, 3.2, 1.0e300] {
    let r = d2_review_chain(Sm2::new(), ease)
    assert_true(r.difficulty >= 1.3)
    assert_false(r.difficulty.is_nan())
  }
  // 具体值回归：2.5 的 Good×3 仍是 1 → 6 → 15
  let chain = d2_review_chain(Sm2::new(), 2.5)
  inspect(chain.interval_days, content="15")
  inspect(chain.difficulty, content="2.5")
}
