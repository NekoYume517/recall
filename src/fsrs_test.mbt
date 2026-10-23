// recall — FSRS-5 公式测试（白盒）
//
// 重点验证「公式写对了」，而不是比对具体浮点字面量：
//   1. 遗忘曲线的定义恒等式 R(S,S) = 0.9
//   2. 间隔公式的自校验 I(S, 0.9) == S（未取整前）
//   3. 各权重项的方向性（单调性 / 符号）
//   4. 截断边界
//
// ⚠️ 浮点断言一律用容差，不用 `inspect`（后者是精确字符串比对，
// 2.7 会变成 "2.7000000000000003"）。

///|
/// 浮点近似比较的容差（不用科学计数法字面量，MoonBit 不支持 1e-9）
let eps : Double = 0.000000001

///|
fn near(a : Double, b : Double) -> Bool {
  let d = a - b
  d.abs() < eps
}

// ---------------------------------------------------------------------------
// 遗忘曲线
// ---------------------------------------------------------------------------

///|
test "fsrs: R(t=S) 精确等于 0.9（S 的定义）" {
  // 这是 FSRS 的根本不变量：稳定性 S 就是"回忆概率衰减到 90% 的天数"
  let cases = [0.40255, 1.18385, 3.173, 15.69105, 50.0, 365.0]
  for s in cases {
    let r = forgetting_curve(s, s)
    assert_true(near(r, 0.9))
  }
}

///|
test "fsrs: R(t=S) 对不同 S 都成立（比例不变性）" {
  // R 只依赖 t/S 的比值
  let base = forgetting_curve(1.0, 1.0)
  let scaled = forgetting_curve(17.0, 17.0)
  assert_true(near(base, scaled))
}

///|
test "fsrs: R(t=0) 等于 1" {
  assert_true(near(forgetting_curve(0.0, 5.0), 1.0))
}

///|
test "fsrs: R(t=2S) 等于 0.8250286473253902 附近的解析值" {
  // (1 + 19/81*2)^(-0.5) = (1 + 38/81)^(-0.5) = (119/81)^(-0.5)
  let r = forgetting_curve(10.0, 5.0)
  assert_true(near(r, 0.8250286473253902))
}

///|
test "fsrs: 曲线严格单调递减" {
  let s = 10.0
  let mut prev = forgetting_curve(0.0, s)
  let mut t = 0.25
  while t <= 120.0 {
    let cur = forgetting_curve(t, s)
    assert_true(cur < prev)
    prev = cur
    t = t + 0.25
  }
}

///|
test "fsrs: 负时间按 0 处理（未到期视为刚复习）" {
  assert_true(near(forgetting_curve(-10.0, 5.0), 1.0))
}

///|
test "fsrs: 稳定性非法（S<=0）时返回 1" {
  assert_true(near(forgetting_curve(5.0, 0.0), 1.0))
  assert_true(near(forgetting_curve(5.0, -3.0), 1.0))
}

///|
test "fsrs: S 越大同一时刻 R 越高" {
  let small = forgetting_curve(10.0, 5.0)
  let big = forgetting_curve(10.0, 50.0)
  assert_true(big > small)
}

///|
test "fsrs: 输出永远落在 [0,1]" {
  let mut t = 0.0
  while t <= 500.0 {
    let r = forgetting_curve(t, 3.173)
    assert_true(r >= 0.0)
    assert_true(r <= 1.0)
    t = t + 7.0
  }
}

// ---------------------------------------------------------------------------
// 权重数组
// ---------------------------------------------------------------------------

///|
test "fsrs: 默认权重 21 项" {
  let w = fsrs_default_w()
  assert_eq(w.length(), 21)
}

///|
test "fsrs: 默认权重前 19 项等于 FSRS-5 官方值" {
  let w = fsrs_default_w()
  let expect = [
    0.40255, 1.18385, 3.173, 15.69105, 7.1949, 0.5345, 1.4604, 0.0046, 1.54575, 0.1192,
    1.01925, 1.9395, 0.11, 0.29605, 2.2698, 0.2315, 2.9898, 0.51655, 0.6621,
  ]
  for i, v in expect {
    assert_true(near(w[i], v))
  }
}

///|
test "fsrs: 权重 19/20 是未使用的占位" {
  let w = fsrs_default_w()
  assert_eq(w[19], 0.0)
  assert_eq(w[20], 0.0)
}

///|
test "fsrs: 默认实例的目标保持率是 0.9" {
  let f = Fsrs::new()
  assert_true(near(f.desired_retention, 0.9))
  assert_true(near(f.desired_retention(), 0.9))
}

///|
test "fsrs: with_retention 修改保持率" {
  let f = Fsrs::with_retention(0.8)
  assert_true(near(f.desired_retention, 0.8))
}

///|
test "fsrs: with_params 权重不足 19 项时退回默认值" {
  let f = Fsrs::with_params([1.0, 2.0])
  assert_eq(f.weights().length(), 21)
  assert_true(near(f.weights()[0], 0.40255))
}

// ---------------------------------------------------------------------------
// 评分刻度
// ---------------------------------------------------------------------------

///|
test "fsrs: fsrs_rating 映射到 1..4（不是 to_int 的 0/2/3/5）" {
  assert_eq(fsrs_rating(Again), 1)
  assert_eq(fsrs_rating(Hard), 2)
  assert_eq(fsrs_rating(Good), 3)
  assert_eq(fsrs_rating(Easy), 4)
}

// ---------------------------------------------------------------------------
// 初始稳定性
// ---------------------------------------------------------------------------

///|
test "fsrs: S_0(g) = w[g-1] 逐个核对" {
  let w = fsrs_default_w()
  assert_true(near(initial_stability(w, 1), 0.40255))
  assert_true(near(initial_stability(w, 2), 1.18385))
  assert_true(near(initial_stability(w, 3), 3.173))
  assert_true(near(initial_stability(w, 4), 15.69105))
}

///|
test "fsrs: S_0 随评分单调递增" {
  let w = fsrs_default_w()
  let s1 = initial_stability(w, 1)
  let s2 = initial_stability(w, 2)
  let s3 = initial_stability(w, 3)
  let s4 = initial_stability(w, 4)
  assert_true(s1 < s2)
  assert_true(s2 < s3)
  assert_true(s3 < s4)
}

///|
test "fsrs: S_0 对越界评分夹到 1..4" {
  let w = fsrs_default_w()
  assert_true(near(initial_stability(w, 0), initial_stability(w, 1)))
  assert_true(near(initial_stability(w, 99), initial_stability(w, 4)))
}

// ---------------------------------------------------------------------------
// 初始难度
// ---------------------------------------------------------------------------

///|
test "fsrs: D_0(1) 等于 w[4]（指数项 exp(0)=1 抵消）" {
  let w = fsrs_default_w()
  // D_0(1) = w[4] - exp(w[5]*0) + 1 = w[4] - 1 + 1 = w[4]
  assert_true(near(initial_difficulty(w, 1), w[4]))
}

///|
test "fsrs: D_0 随评分单调递减" {
  let w = fsrs_default_w()
  let d1 = initial_difficulty(w, 1)
  let d2 = initial_difficulty(w, 2)
  let d3 = initial_difficulty(w, 3)
  let d4 = initial_difficulty(w, 4)
  assert_true(d1 > d2)
  assert_true(d2 > d3)
  assert_true(d3 > d4)
}

///|
test "fsrs: D_0 始终落在 [1,10]" {
  let w = fsrs_default_w()
  for g = 1; g <= 4; g = g + 1 {
    let d = initial_difficulty(w, g)
    assert_true(d >= 1.0)
    assert_true(d <= 10.0)
  }
}

///|
test "fsrs: D_0 被截断到 [1,10]（极端权重）" {
  let w_hi = fsrs_default_w()
  w_hi[4] = 100.0
  assert_eq(initial_difficulty(w_hi, 1), 10.0)
  let w_lo = fsrs_default_w()
  w_lo[4] = -100.0
  assert_eq(initial_difficulty(w_lo, 1), 1.0)
}

// ---------------------------------------------------------------------------
// 难度更新
// ---------------------------------------------------------------------------

///|
test "fsrs: Good（g=3）只做均值回归，难度几乎不动" {
  let w = fsrs_default_w()
  let before = 5.0
  let after = next_difficulty(w, before, 3)
  // delta_D = -w[6]*(3-3) = 0，只剩 w[7]=0.0046 的回归
  let d = after - before
  assert_true(d.abs() < 0.1)
}

///|
test "fsrs: Again（g=1）使难度上升" {
  let w = fsrs_default_w()
  let after = next_difficulty(w, 5.0, 1)
  // delta_D = -w[6]*(1-3) = +2*w[6] > 0
  assert_true(after > 5.0)
}

///|
test "fsrs: Easy（g=4）使难度下降" {
  let w = fsrs_default_w()
  let after = next_difficulty(w, 5.0, 4)
  // delta_D = -w[6]*(4-3) = -w[6] < 0
  assert_true(after < 5.0)
}

///|
test "fsrs: 难度在反复 Again 下不越界" {
  let w = fsrs_default_w()
  let mut d = 9.0
  let mut i = 0
  while i < 50 {
    d = next_difficulty(w, d, 1)
    assert_true(d >= 1.0)
    assert_true(d <= 10.0)
    i = i + 1
  }
}

// ---------------------------------------------------------------------------
// linear damping（回归测试：曾经漏掉 (10-D)/9 导致难度顶死在 10）
// ---------------------------------------------------------------------------

///|
test "fsrs: linear damping —— 增量随当前难度递减" {
  let w = fsrs_default_w()
  // 同一个评分，从低 D 出发的增量必须大于从高 D 出发的增量
  let from_low = next_difficulty(w, 1.0, 1) - 1.0
  let from_mid = next_difficulty(w, 5.0, 1) - 5.0
  let from_high = next_difficulty(w, 9.9, 1) - 9.9
  assert_true(from_low > from_mid)
  assert_true(from_mid > from_high)
  // D=1 时阻尼系数 = (10-1)/9 = 1.0，即全量推进
  // raw_delta = -w[6]*(1-3) = 2*w[6] = 2.9208，再加上回归
  assert_true(from_low > 2.9)
  // D=9.9 时阻尼系数 ≈ 0.0111，增量应接近 0
  assert_true(from_high < 0.05)
}

///|
test "fsrs: linear damping —— D=8 连续 Again 是平滑收敛，不是一次顶死" {
  let w = fsrs_default_w()
  // 回归 lead 裁决里的实测曲线：8.62 → 9.04 → 9.33 → 9.52 → 9.64
  let mut d = 8.0
  let seq : Array[Double] = []
  let mut i = 0
  while i < 5 {
    d = next_difficulty(w, d, 1)
    seq.push(d)
    i = i + 1
  }
  // 第一步绝不能直接到 10（无阻尼版会）
  assert_true(seq[0] < 9.0)
  // 严格单调递增
  assert_true(seq[0] < seq[1])
  assert_true(seq[1] < seq[2])
  assert_true(seq[2] < seq[3])
  assert_true(seq[3] < seq[4])
  // 且始终保持分辨率（不到 10）
  assert_true(seq[4] < 10.0)
  // 增量逐次缩小（这是阻尼的核心效果）
  let g0 = seq[0] - 8.0
  let g1 = seq[1] - seq[0]
  let g2 = seq[2] - seq[1]
  assert_true(g0 > g1)
  assert_true(g1 > g2)
}

///|
test "fsrs: linear damping —— D 的解析值逐项核对（g=1）" {
  let w = fsrs_default_w()
  // D=5, g=1:
  //   raw = -w[6]*(1-3) = 2.9208
  //   damping = (10-5)/9 = 5/9 = 0.5556
  //   delta = 1.6227
  //   D' = 6.6227，再叠加 w[7]=0.0046 的回归
  let got = next_difficulty(w, 5.0, 1)
  assert_true(got > 6.6)
  assert_true(got < 6.65)
}

///|
test "fsrs: linear damping —— Easy 方向同样被阻尼" {
  let w = fsrs_default_w()
  // g=4 时 raw = -w[6]*(4-3) = -1.4604
  // 从 D=5 出发，delta = -1.4604*(10-5)/9 = -0.8113
  // 从 D=9.9 出发，delta = -1.4604*(0.1)/9 ≈ -0.0162
  let from_mid = 5.0 - next_difficulty(w, 5.0, 4)
  let from_high = 9.9 - next_difficulty(w, 9.9, 4)
  assert_true(from_mid > from_high)
  assert_true(from_mid > 0.7)
  assert_true(from_high < 0.05)
}

// ---------------------------------------------------------------------------
// 状态转移：D' 与 S' 均使用复习前状态（回归测试）
// ---------------------------------------------------------------------------

///|
test "fsrs: 成功路径使用旧 D（官方状态转移）" {
  let w = fsrs_default_w()
  let old_d = 5.0
  let s = 10.0
  let elapsed = 3.0
  let r = forgetting_curve(elapsed, s)
  let d_new = next_difficulty(w, old_d, 3)
  let s_expect = stability_after_success(w, old_d, s, r, 3)
  let s_new_d = stability_after_success(w, d_new, s, r, 3)
  let (s_got, d_got, _iv) = step(w, 0.9, old_d, s, elapsed, 3, false)
  // 与官方 last_d 路径一致，同时返回单独更新的新难度。
  assert_true(near(s_got, s_expect))
  assert_true(near(d_got, d_new))
  assert_true(!near(s_got, s_new_d))
}

///|
test "fsrs: 遗忘路径也使用旧 D" {
  let w = fsrs_default_w()
  let old_d = 5.0
  let s = 20.0
  let elapsed = 10.0
  let r = forgetting_curve(elapsed, s)
  let d_new = next_difficulty(w, old_d, 1)
  let s_expect = stability_after_lapse(w, old_d, s, r)
  let s_new_d = stability_after_lapse(w, d_new, s, r)
  let (s_got, _d, _iv) = step(w, 0.9, old_d, s, elapsed, 1, false)
  assert_true(near(s_got, s_expect))
  assert_true(!near(s_got, s_new_d))
}

///|
test "fsrs: Good ×5 的间隔序列（旧 D 与阻尼）" {
  // FSRS-5 公式原值独立复算后取整：3 → 11 → 35 → 101 → 269。
  let f = Fsrs::new()
  let mut st = f.init("c1", 0L)
  let mut now : Timestamp = 0L
  let ivs : Array[Double] = []
  let mut i = 0
  while i < 5 {
    st = f.review(st, Grade::Good, now)
    ivs.push(st.interval_days)
    now = st.due
    i = i + 1
  }
  assert_true(near(ivs[0], 3.0))
  assert_true(near(ivs[1], 11.0))
  assert_true(near(ivs[2], 35.0))
  assert_true(near(ivs[3], 101.0))
  assert_true(near(ivs[4], 269.0))
}

///|
test "fsrs: 难度在反复 Easy 下不越界" {
  let w = fsrs_default_w()
  let mut d = 2.0
  let mut i = 0
  while i < 50 {
    d = next_difficulty(w, d, 4)
    assert_true(d >= 1.0)
    assert_true(d <= 10.0)
    i = i + 1
  }
}

///|
test "fsrs: 均值回归把难度慢慢拉向 D_0(Easy)" {
  let w = fsrs_default_w()
  let d0_easy = initial_difficulty(w, 4)
  // 从远离 D_0(Easy) 的起点出发，反复 Good，难度应向 D_0(Easy) 靠拢
  let mut d = 10.0
  let dist_before = (d - d0_easy).abs()
  let mut i = 0
  while i < 2000 {
    d = next_difficulty(w, d, 3)
    i = i + 1
  }
  let dist_after = (d - d0_easy).abs()
  assert_true(dist_after < dist_before)
}

// ---------------------------------------------------------------------------
// 成功回忆的稳定性增长
// ---------------------------------------------------------------------------

///|
test "fsrs: 成功回忆使稳定性严格增加" {
  let w = fsrs_default_w()
  for g in [2, 3, 4] {
    let next = stability_after_success(w, 5.0, 5.0, 0.9, g)
    assert_true(next > 5.0)
  }
}

///|
test "fsrs: Hard 增益 < Good 增益 < Easy 增益" {
  let w = fsrs_default_w()
  let hard = stability_after_success(w, 5.0, 5.0, 0.9, 2)
  let good = stability_after_success(w, 5.0, 5.0, 0.9, 3)
  let easy = stability_after_success(w, 5.0, 5.0, 0.9, 4)
  assert_true(hard < good)
  assert_true(good < easy)
}

///|
test "fsrs: R 越低，成功回忆的增益越大（合意困难）" {
  let w = fsrs_default_w()
  let high_r = stability_after_success(w, 5.0, 5.0, 0.95, 3)
  let low_r = stability_after_success(w, 5.0, 5.0, 0.60, 3)
  assert_true(low_r > high_r)
}

///|
test "fsrs: 难度越高，成功回忆的增益越小" {
  let w = fsrs_default_w()
  let easy_card = stability_after_success(w, 2.0, 5.0, 0.9, 3)
  let hard_card = stability_after_success(w, 9.0, 5.0, 0.9, 3)
  assert_true(easy_card > hard_card)
}

///|
test "fsrs: 稳定性越大，相对增益越小（边际递减）" {
  let w = fsrs_default_w()
  let small_s = stability_after_success(w, 5.0, 1.0, 0.9, 3)
  let big_s = stability_after_success(w, 5.0, 100.0, 0.9, 3)
  let ratio_small = small_s / 1.0
  let ratio_big = big_s / 100.0
  assert_true(ratio_small > ratio_big)
}

///|
test "fsrs: R=1 时增益项为零（exp(0)-1=0），稳定性不变" {
  let w = fsrs_default_w()
  let next = stability_after_success(w, 5.0, 5.0, 1.0, 3)
  // w[10]*(1-1)=0 → exp(0)-1=0 → multiplier=1
  assert_true(near(next, 5.0))
}

///|
test "fsrs: 增长结果永不小于 0.1" {
  let w = fsrs_default_w()
  let next = stability_after_success(w, 10.0, 0.1, 0.05, 2)
  assert_true(next >= 0.1)
}

// ---------------------------------------------------------------------------
// 遗忘后的稳定性
// ---------------------------------------------------------------------------

///|
test "fsrs: 遗忘后稳定性低于原稳定性" {
  let w = fsrs_default_w()
  let next = stability_after_lapse(w, 5.0, 20.0, 0.9)
  assert_true(next < 20.0)
}

///|
test "fsrs: 遗忘后稳定性与难度负相关" {
  let w = fsrs_default_w()
  let easy = stability_after_lapse(w, 2.0, 20.0, 0.7)
  let hard = stability_after_lapse(w, 9.0, 20.0, 0.7)
  assert_true(easy > hard)
}

///|
test "fsrs: 遗忘后稳定性与原稳定性正相关" {
  let w = fsrs_default_w()
  let from_weak = stability_after_lapse(w, 5.0, 2.0, 0.9)
  let from_strong = stability_after_lapse(w, 5.0, 200.0, 0.9)
  assert_true(from_strong > from_weak)
}

///|
test "fsrs: 遗忘后稳定性永为正" {
  let w = fsrs_default_w()
  let next = stability_after_lapse(w, 10.0, 0.1, 0.0)
  assert_true(next > 0.0)
  assert_true(next >= 0.1)
}

// ---------------------------------------------------------------------------
// 间隔
// ---------------------------------------------------------------------------

///|
test "fsrs: 间隔公式自校验 I(S, 0.9) 未取整前恒等于 S" {
  // 因为 0.9^(1/-0.5) - 1 = 0.9^(-2) - 1 = 100/81 - 1 = 19/81 = FACTOR
  // 于是 I = S/FACTOR * FACTOR = S
  // 取整后 round(S) 应等于 round(S)
  let cases = [3.173, 15.69105, 0.40255, 1.18385]
  for s in cases {
    let iv = interval_days(s, 0.9)
    let expect = @math.round(s)
    let want = if expect < 1.0 { 1.0 } else { expect }
    assert_true(near(iv, want))
  }
}

///|
test "fsrs: interval_days(S,0.9)=S 只在 S ∈ [1, 36500] 内成立" {
  // 恒等式是「未取整且未被夹取」时的结果。实现最后一步会把结果
  // 四舍五入并夹到 [1, max_interval_days()]：
  //   - S < 1：0 天间隔没有意义，夹到 1 天（如 0.1 → 1）
  //   - S > 36500：夹到 100 年上限（如 40000 → 36500），防 Int64 回绕
  // 区间内取整数 S 时精确相等；这正是 docs/DEMO.md 与 API.md 的契约。
  for s in [1.0, 2.0, 30.0, 365.0, 36000.0] {
    assert_eq(interval_days(s, 0.9), s)
  }
  assert_eq(interval_days(36500.0, 0.9), 36500.0)
  assert_eq(interval_days(0.1, 0.9), 1.0)
  assert_eq(interval_days(40000.0, 0.9), 36500.0)
  // 夹取后仍为正、不超过上限（值是安全的，不是恒等式的结果）
  assert_true(interval_days(1.0e18, 0.9) <= max_interval_days())
  assert_eq(interval_days(1.0e18, 0.9), max_interval_days())
}

///|
test "fsrs: 间隔至少 1 天" {
  assert_eq(interval_days(0.0, 0.9), 1.0)
  assert_eq(interval_days(0.01, 0.9), 1.0)
  assert_eq(interval_days(-5.0, 0.9), 1.0)
}

///|
test "fsrs: 间隔是四舍五入的整数" {
  let iv = interval_days(7.7, 0.9)
  assert_eq(iv, 8.0)
  let iv2 = interval_days(7.4, 0.9)
  assert_eq(iv2, 7.0)
}

///|
test "fsrs: 目标保持率越高，间隔越短" {
  let s = 20.0
  let loose = interval_days(s, 0.80)
  let strict = interval_days(s, 0.95)
  assert_true(strict < loose)
}

///|
test "fsrs: 稳定性越高，间隔越长" {
  let a = interval_days(5.0, 0.9)
  let b = interval_days(50.0, 0.9)
  assert_true(b > a)
}

///|
test "fsrs: 保持率参数被夹到 [0.5, 0.99]" {
  // 越界输入不应产生 0 或负间隔
  let a = interval_days(10.0, 0.0)
  assert_true(a >= 1.0)
  let b = interval_days(10.0, 1.5)
  assert_true(b >= 1.0)
}

// ---------------------------------------------------------------------------
// Scheduler trait 行为
// ---------------------------------------------------------------------------

///|
test "fsrs: name 是 fsrs" {
  assert_eq(Fsrs::new().name(), "fsrs")
}

///|
test "fsrs: init 产生空白新卡" {
  let st = Fsrs::new().init("c1", 1000L)
  assert_eq(st.card_id, "c1")
  assert_eq(st.phase, New)
  assert_eq(st.reps, 0)
  assert_eq(st.lapses, 0)
  assert_true(near(st.stability, 0.0))
  assert_eq(st.last_review, 1000L)
  assert_eq(st.due, 1000L)
}

///|
test "fsrs: 首次 Good 得到 S_0(Good)" {
  let f = Fsrs::new()
  let next = f.review(f.init("c1", 0L), Good, 0L)
  assert_true(near(next.stability, 3.173))
  assert_eq(next.reps, 1)
  assert_eq(next.lapses, 0)
  assert_eq(next.phase, Learning)
}

///|
test "fsrs: 首次 Again 得到 S_0(Again) 且记一次遗忘" {
  let f = Fsrs::new()
  let next = f.review(f.init("c1", 0L), Again, 0L)
  assert_true(near(next.stability, 0.40255))
  assert_eq(next.reps, 0)
  assert_eq(next.lapses, 1)
  assert_eq(next.phase, Relearning)
}

///|
test "fsrs: 首次 Easy 得到 S_0(Easy) 且间隔最长" {
  let f = Fsrs::new()
  let good = f.review(f.init("c1", 0L), Good, 0L)
  let easy = f.review(f.init("c1", 0L), Easy, 0L)
  assert_true(near(easy.stability, 15.69105))
  assert_true(easy.interval_days > good.interval_days)
}

///|
test "fsrs: due = now + interval" {
  let f = Fsrs::new()
  let next = f.review(f.init("c1", 1000L), Good, 1000L)
  let expect = 1000L + (next.interval_days * 86400.0).to_int64()
  // add_days 用 round，容忍 1 秒误差
  let diff = next.due - expect
  assert_true(diff.abs() <= 1L)
}

///|
test "fsrs: review 不修改入参（纯函数）" {
  let f = Fsrs::new()
  let st = f.init("c1", 0L)
  let before_s = st.stability
  let _next = f.review(st, Good, 0L)
  assert_true(near(st.stability, before_s))
  assert_eq(st.reps, 0)
}

///|
test "fsrs: retrievability 在 due 时刻为 0.9" {
  // 用整数稳定性避免秒级截断误差：S=5.0 → 5*86400 秒精确
  let w = fsrs_default_w()
  w[2] = 5.0
  let f = Fsrs::with_params(w)
  let after = f.review(f.init("c1", 0L), Good, 0L)
  assert_true(near(after.stability, 5.0))
  let dt = (after.stability * 86400.0).to_int64()
  let r = f.retrievability(after, after.last_review + dt)
  assert_true(near(r, 0.9))
}

///|
test "fsrs: retrievability 随逾期单调下降" {
  let f = Fsrs::new()
  let st = f.review(f.init("c1", 0L), Good, 0L)
  let mut prev = f.retrievability(st, st.last_review)
  let mut day = 1
  while day <= 60 {
    let r = f.retrievability(st, st.last_review + day.to_int64() * 86400L)
    assert_true(r < prev)
    prev = r
    day = day + 1
  }
}

///|
test "fsrs: 连续 Good 的间隔单调不减" {
  let f = Fsrs::new()
  let mut st = f.init("c1", 0L)
  let mut now : Timestamp = 0L
  let mut prev = 0.0
  let mut i = 0
  while i < 10 {
    st = f.review(st, Good, now)
    assert_true(st.interval_days >= prev)
    prev = st.interval_days
    now = st.due
    i = i + 1
  }
}

///|
test "fsrs: 同一状态下 Good 的间隔 >= Hard 的间隔" {
  let f = Fsrs::new()
  let base = f.review(f.init("c1", 0L), Good, 0L)
  let now = base.due
  let hard = f.review(base, Hard, now)
  let good = f.review(base, Good, now)
  assert_true(good.interval_days >= hard.interval_days)
}

///|
test "fsrs: 同一状态下 Easy 的间隔 >= Good 的间隔" {
  let f = Fsrs::new()
  let base = f.review(f.init("c1", 0L), Good, 0L)
  let now = base.due
  let good = f.review(base, Good, now)
  let easy = f.review(base, Easy, now)
  assert_true(easy.interval_days >= good.interval_days)
}

///|
test "fsrs: 中途 Once Again 触发 Relearning 且 lapses 累加" {
  let f = Fsrs::new()
  let mut st = f.init("c1", 0L)
  st = f.review(st, Good, 0L)
  st = f.review(st, Good, st.due)
  let lapsed = f.review(st, Again, st.due)
  assert_eq(lapsed.phase, Relearning)
  assert_eq(lapsed.lapses, 1)
  assert_eq(lapsed.reps, st.reps)
}

///|
test "fsrs: 遗忘后继续 Good 能回到 Review 阶段" {
  let f = Fsrs::new()
  let mut st = f.init("c1", 0L)
  st = f.review(st, Good, 0L)
  st = f.review(st, Again, st.due)
  assert_eq(st.phase, Relearning)
  st = f.review(st, Good, st.due)
  assert_eq(st.phase, Review)
}

///|
test "fsrs: 同输入同输出（确定性）" {
  let f = Fsrs::new()
  let a = f.review(f.init("x", 0L), Good, 0L)
  let b = f.review(f.init("x", 0L), Good, 0L)
  assert_true(near(a.stability, b.stability))
  assert_true(near(a.difficulty, b.difficulty))
  assert_true(near(a.interval_days, b.interval_days))
}

///|
test "fsrs: step 首次走初始公式，后续走曲线" {
  let w = fsrs_default_w()
  let (s1, d1, _iv1) = step(w, 0.9, 5.0, 0.0, 0.0, 3, true)
  assert_true(near(s1, 3.173))
  assert_true(near(d1, initial_difficulty(w, 3)))
  // 已有稳定性时不再走初始公式
  let (s2, _d2, _iv2) = step(w, 0.9, 5.0, 10.0, 10.0, 3, false)
  assert_true(s2 > 10.0)
}

///|
test "fsrs: 高目标保持率让复习更频繁（间隔更短）" {
  let f90 = Fsrs::with_retention(0.9)
  let f97 = Fsrs::with_retention(0.97)
  let a = f90.review(f90.init("c1", 0L), Good, 0L)
  let b = f97.review(f97.init("c1", 0L), Good, 0L)
  assert_true(b.interval_days < a.interval_days)
}
