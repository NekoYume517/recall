// recall — FSRS-5 公开公式实现
//
// 合同：API.md 第 3.2 节。
//
// 本文件**只提供公式与 `impl Scheduler for Fsrs`**。
// `struct Fsrs`、`Fsrs::new()`、`Fsrs::with_params()`、`Fsrs::with_retention()`、
// `fsrs_default_w()` 由 `src/scheduler.mbt` 提供（那边是中枢纽，AnyScheduler
// 需要引用这些类型），此处**不重复定义**。
//
// 参考：
//   Ye et al., "FSRS: A modern, efficient spaced repetition scheduler" (2023)
//   open-spaced-repetition 的默认权重（19 个官方值 + 2 个扩展位）
//
// 只实现推理（给定权重计算），不实现权重训练。

// ---------------------------------------------------------------------------
// 常量
// ---------------------------------------------------------------------------

///|
/// 遗忘曲线衰减指数：DECAY = -0.5。
///
/// 它由 "S 的定义 = 回忆概率衰减到 90% 所需天数" 反解得到：
///   (1 + FACTOR)^DECAY = 0.9  =>  (1 + 19/81)^(-0.5) = (100/81)^(-0.5) = 0.9
let decay : Double = -0.5

///|
/// 遗忘曲线缩放因子：FACTOR = 19/81。
///
/// 与 DECAY 配对，使 R(t=S) = 0.9 精确成立。
let factor : Double = 19.0 / 81.0

// ---------------------------------------------------------------------------
// 遗忘曲线
// ---------------------------------------------------------------------------

///|
/// 遗忘曲线 R(t, S) = (1 + FACTOR · t / S) ^ DECAY。
///
/// - `t`：距上次复习的天数（负数按 0 处理，未来时刻视为"刚刚复习"）
/// - `s`：稳定性 S（保持天数）；S ≤ 0 时视为"尚无记忆"，返回 1
///
/// 关键恒等式：**R(S, S) = 0.9**。这是 FSRS 里 S 的定义，也是全套测试的锚点。
pub fn forgetting_curve(t : Double, s : Double) -> Double {
  if s <= 0.0 {
    return 1.0
  }
  let tt = if t < 0.0 { 0.0 } else { t }
  clamp_retrievability(@math.pow(1.0 + factor * tt / s, decay))
}

///|
/// 可提取性的权重化入口。当前 FSRS-5 的 R 不依赖权重，
/// 保留这个签名是为了将来 FSRS-6 引入可学习衰减时不必改调用点。
pub fn retrievability_with(w : Array[Double], t : Double, s : Double) -> Double {
  let _ = w
  forgetting_curve(t, s)
}

// ---------------------------------------------------------------------------
// 评分刻度
// ---------------------------------------------------------------------------

///|
/// Grade → FSRS 的 1..4 评分刻度。
///
/// ⚠️ 这**不是** `Grade::to_int`（后者是展示用 0/2/3/5），
/// 也**不是** SM-2 的 q（2/3/4/5）。FSRS 用 1..4：
///   Again → 1, Hard → 2, Good → 3, Easy → 4
pub fn fsrs_rating(g : Grade) -> Int32 {
  match g {
    Again => 1
    Hard => 2
    Good => 3
    Easy => 4
  }
}

// ---------------------------------------------------------------------------
// 初始状态：S_0 / D_0
// ---------------------------------------------------------------------------

///|
/// 初始稳定性 S_0(g) = w[g-1]，g ∈ 1..4。
///
///   Again → w[0] = 0.40255
///   Hard  → w[1] = 1.18385
///   Good  → w[2] = 3.173
///   Easy  → w[3] = 15.69105
///
/// 权重为负或过小时夹到 0.1，避免 S=0 导致后续 S^(-w[9]) 发散。
pub fn initial_stability(w : Array[Double], rating : Int32) -> Double {
  let g = if rating < 1 { 1 } else if rating > 4 { 4 } else { rating }
  let idx = g - 1 // ← w 的下标就是评分减一
  if idx >= w.length() {
    return 1.0
  }
  let s = w[idx]
  if s < 0.1 {
    0.1
  } else {
    s
  }
}

///|
/// 初始难度 D_0(g) = w[4] - exp(w[5] · (g - 1)) + 1，截断到 [1, 10]。
///
/// - `w[4]`：难度基准（常数项，默认 7.1949）
/// - `w[5]`：对评分的敏感度（默认 0.5345，指数项的系数）
///
/// g=1 时指数项为 exp(0)=1，于是 D_0(1) = w[4]，正好落在 [1,10] 内。
pub fn initial_difficulty(w : Array[Double], rating : Int32) -> Double {
  let g = rating.to_double()
  // w[4]：基准；w[5]：敏感度
  let d = w[4] - @math.exp(w[5] * (g - 1.0)) + 1.0
  clamp_difficulty(d)
}

///|
/// 难度夹到 [1, 10]。
fn clamp_difficulty(d : Double) -> Double {
  if d.is_nan() {
    5.0
  } else if d < 1.0 {
    1.0
  } else if d > 10.0 {
    10.0
  } else {
    d
  }
}

// ---------------------------------------------------------------------------
// 难度更新
// ---------------------------------------------------------------------------

///|
/// 难度更新：
///
///   delta_D = -w[6] · (g - 3)          // w[6]：难度增量系数（默认 1.4604）
///   D'      = D + delta_D
///   D''     = w[7] · D_0(4) + (1 - w[7]) · D'   // w[7]：均值回归强度（默认 0.0046）
///   截断到 [1, 10]
///
/// 直觉：
/// - g=3(Good) → delta_D = 0，只做均值回归（几乎不动）
/// - g=1(Again) → delta_D = +2·w[6]，难度上升
/// - g=4(Easy)  → delta_D = -w[6]，难度下降
/// - 均值回归把难度慢慢拉向 D_0(Easy)，防止难度无限漂移
pub fn next_difficulty(w : Array[Double], d : Double, rating : Int32) -> Double {
  let g = rating.to_double()
  // w[6]：每次评分相对"Good"的偏离量
  let delta_d = -w[6] * (g - 3.0)
  let d_prime = d + delta_d
  // w[7]：回归到 D_0(Easy) 的强度
  let d0_easy = initial_difficulty(w, 4)
  let reverted = w[7] * d0_easy + (1.0 - w[7]) * d_prime
  clamp_difficulty(reverted)
}

// ---------------------------------------------------------------------------
// 稳定性更新
// ---------------------------------------------------------------------------

///|
/// 成功回忆后的稳定性增长（rating ∈ {2,3,4}，即 Hard/Good/Easy）：
///
///   S' = S · (1 + exp(w[8])
///               · (11 - D)
///               · S^(-w[9])
///               · (exp(w[10] · (1 - R)) - 1)
///               · (w[15] if g == 2 else 1)
///               · (w[16] if g == 4 else 1))
///
/// 逐项含义：
/// - `exp(w[8])`：增益整体缩放（w[8] ≈ 1.55 → 约 4.7 倍）
/// - `(11 - D)`：难度越低增益越大（D ∈ [1,10]，所以因子 ∈ [1,10]）
/// - `S^(-w[9])`：稳定性越大增益越小，即边际递减（w[9] ≈ 0.12）
/// - `exp(w[10]·(1-R)) - 1`：R 越低（越接近遗忘）成功回忆带来的增益越大（w[10] ≈ 1.02）
/// - `w[15]`：Hard 惩罚因子（只在 g==2 乘入，≈ 0.23）
/// - `w[16]`：Easy 奖励因子（只在 g==4 乘入，≈ 2.99）
pub fn stability_after_success(
  w : Array[Double],
  d : Double,
  s : Double,
  r : Double,
  rating : Int32,
) -> Double {
  let gain_scale = @math.exp(w[8]) // w[8]：整体缩放
  let difficulty_term = 11.0 - d // 难度项（D 越小增益越大）
  let stability_decay = @math.pow(s, -w[9]) // w[9]：稳定性边际递减指数
  let retrievability_term = @math.exp(w[10] * (1.0 - r)) - 1.0 // w[10]：R 越低增益越大
  let hard_factor = if rating == 2 { w[15] } else { 1.0 } // w[15]：Hard 惩罚
  let easy_factor = if rating == 4 { w[16] } else { 1.0 } // w[16]：Easy 奖励
  let gain = gain_scale *
    difficulty_term *
    stability_decay *
    retrievability_term
  let multiplier = 1.0 + gain * hard_factor * easy_factor
  let next = s * multiplier
  if next < 0.1 {
    0.1
  } else {
    next
  }
}

///|
/// 遗忘后的稳定性（rating == 1，即 Again）：
///
///   S' = w[11] · D^(-w[12]) · ((S+1)^w[13] - 1) · exp(w[14] · (1 - R))
///
/// 逐项含义：
/// - `w[11]`：遗忘后稳定性基准（≈ 1.94）
/// - `D^(-w[12])`：难度越高，遗忘后越不稳定（w[12] ≈ 0.11）
/// - `(S+1)^w[13] - 1`：原稳定性越高，遗忘后仍保留更多（w[13] ≈ 0.296）
/// - `exp(w[14]·(1-R))`：R 越低（拖得越久才复习）遗忘后反而更稳（w[14] ≈ 2.27）
///
/// 注意：这条公式**不复用**成功路径，是 FSRS 相对 SM-2 的关键改进之一
/// ——遗忘不是"把间隔清零"，而是按原记忆强度打折。
pub fn stability_after_lapse(
  w : Array[Double],
  d : Double,
  s : Double,
  r : Double,
) -> Double {
  let base = w[11] // w[11]：基准
  let difficulty_term = @math.pow(d, -w[12]) // w[12]：难度指数
  let stability_term = @math.pow(s + 1.0, w[13]) - 1.0 // w[13]：原稳定性幂次
  let retrievability_term = @math.exp(w[14] * (1.0 - r)) // w[14]：R 修正
  let next = base * difficulty_term * stability_term * retrievability_term
  if next < 0.1 {
    0.1
  } else {
    next
  }
}

// ---------------------------------------------------------------------------
// 间隔
// ---------------------------------------------------------------------------

///|
/// 由稳定性反解下次间隔（天）：
///
///   I = S / FACTOR · (desired_retention^(1/DECAY) - 1)
///   至少 1 天，四舍五入（@math.round 是 half-up，实测 round(2.5)=3）
///
/// 推导：令 R(I, S) = dr，即 (1 + FACTOR·I/S)^DECAY = dr，
/// 解出 I = S/FACTOR · (dr^(1/DECAY) - 1)。
///
/// 当 dr = 0.9 时 dr^(1/DECAY) - 1 = 0.9^(-2) - 1 = 100/81 - 1 = 19/81 = FACTOR，
/// 于是 **I = S**（未取整前）。这条恒等式是间隔公式的自检点。
///
/// **上限保护（重要）**：连续 Easy 会让 S 指数增长
/// （60 次 Easy 后 S ≈ 2e15 天），而 `due = now + I*86400` 会超出 Int64
/// 表示范围、回绕成负数 —— 卡片就变成"永久到期"，所有统计与模拟全废。
/// 因此这里把结果夹到 `max_interval_days()`（100 年）。
/// `add_days` 内部也有一层同样的夹取，双层防护。
pub fn interval_days(s : Double, desired_retention : Double) -> Double {
  let s_eff = if s < 0.1 { 0.1 } else { s }
  let dr = if desired_retention < 0.5 {
    0.5
  } else if desired_retention > 0.99 {
    0.99
  } else {
    desired_retention
  }
  let raw = s_eff / factor * (@math.pow(dr, 1.0 / decay) - 1.0)
  // NaN / Infinity 兜底：pow 在极端参数下可能给出非有限值
  let safe = if raw.is_nan() || raw < 0.0 { 1.0 } else { raw }
  let rounded = @math.round(safe)
  let cap = max_interval_days()
  if rounded < 1.0 {
    1.0
  } else if rounded > cap {
    cap
  } else {
    rounded
  }
}

// ---------------------------------------------------------------------------
// 单步推进（供 impl 与测试共用）
// ---------------------------------------------------------------------------

///|
/// 一次复习的完整推进，返回 (新稳定性, 新难度, 新间隔天数)。
///
/// `elapsed_days` 由调用方按 `state.last_review` 与 `now` 算出。
/// `is_first` 为真时走初始公式（不查遗忘曲线）。
pub fn step(
  w : Array[Double],
  desired_retention : Double,
  d : Double,
  s : Double,
  elapsed_days : Double,
  rating : Int32,
  is_first : Bool,
) -> (Double, Double, Double) {
  if is_first || s <= 0.0 {
    let s0 = initial_stability(w, rating)
    let d0 = initial_difficulty(w, rating)
    return (s0, d0, interval_days(s0, desired_retention))
  }
  // 当前可提取性
  let r = forgetting_curve(elapsed_days, s)
  // 难度先更新（FSRS-5 里 D 的更新不依赖 R）
  let d_next = next_difficulty(w, d, rating)
  // 稳定性按评分分支
  let s_next = if rating == 1 {
    stability_after_lapse(w, d, s, r)
  } else {
    stability_after_success(w, d, s, r, rating)
  }
  (s_next, d_next, interval_days(s_next, desired_retention))
}

// ---------------------------------------------------------------------------
// impl Scheduler for Fsrs
// ---------------------------------------------------------------------------

///|
/// 调度器名字。
pub impl Scheduler for Fsrs with fn name(self) {
  "fsrs"
}

///|
/// 新卡初始化。
///
/// 用 `stability = 0` 表示"尚未建立记忆"：`review` 见到它就走初始公式
/// （S_0(g) 与 D_0(g)）。难度初值给 0 也无所谓，同样会被覆写。
pub impl Scheduler for Fsrs with fn init(self, card_id, now) {
  CardState::new(card_id, now)
}

///|
/// 应用一次复习。
pub impl Scheduler for Fsrs with fn review(self, state, grade, now) {
  let rating = fsrs_rating(grade)
  let elapsed = days_between(state.last_review, now)
  let is_first = state.phase == New || state.stability <= 0.0
  let (s_next, d_next, iv) = step(
    self.w,
    self.desired_retention,
    state.difficulty,
    state.stability,
    elapsed,
    rating,
    is_first,
  )
  let lapsed = rating == 1
  let phase = if lapsed {
    Relearning
  } else if is_first {
    Learning
  } else {
    Review
  }
  {
    card_id: state.card_id,
    stability: s_next,
    difficulty: d_next,
    // 只有成功回忆才增加 reps（与 trait 文档一致）
    reps: if lapsed {
      state.reps
    } else {
      state.reps + 1
    },
    lapses: if lapsed {
      state.lapses + 1
    } else {
      state.lapses
    },
    last_review: now,
    due: add_days(now, iv),
    interval_days: iv,
    phase,
  }
}

///|
/// 当前可提取性：直接走 FSRS 遗忘曲线，因此这是三种调度器里
/// **唯一有物理意义**的 retrievability。
pub impl Scheduler for Fsrs with fn retrievability(self, state, now) {
  let elapsed = days_between(state.last_review, now)
  forgetting_curve(elapsed, state.stability)
}

///|
/// 目标保持率：取实例配置（默认 0.9）。
pub impl Scheduler for Fsrs with fn desired_retention(self) {
  self.desired_retention
}
