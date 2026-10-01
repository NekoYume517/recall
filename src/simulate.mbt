// recall — 未来负载模拟
//
// 合同：API.md 第 5 节（签名已按 CONTRACT-FIX.md 修正为 AnyScheduler）。
//
// 这是项目最有价值的输出：回答"如果我每天学 N 张新卡，三个月后积压多少"。
//
// **确定性是硬性要求**：伪随机用手写的 LCG，固定种子，不用 @random、
// 不用系统时间。同一配置跑两次，逐日结果必须逐字段相同。
//
// ⚠️ MoonBit 的 Int 是 32 位有符号（wasm 目标实测），乘法会溢出回绕。
// 因此 LCG 全程用 Int64 承载，再用 0x7FFFFFFF 掩码取低 31 位。

// ---------------------------------------------------------------------------
// 线性同余伪随机数（LCG）
// ---------------------------------------------------------------------------

///|
/// 乘数。1103515245 是 Numerical Recipes 的经典取值，低 31 位周期足够长。
let lcg_mul : Int64 = 1103515245L

///|
/// 增量。12345 与上式配对，构成 ANSI C 的经典 LCG。
let lcg_add : Int64 = 12345L

///|
/// 掩码：只保留低 31 位，保证结果非负。
let lcg_mask : Int64 = 0x7FFFFFFFL

///|
/// 归一化分母：2^31 - 1，把 Int64 状态映射到 [0, 1)。
let lcg_denom : Double = 2147483647.0

///|
/// LCG 推进一步：`state' = (state * 1103515245 + 12345) & 0x7FFFFFFF`。
pub fn lcg_next(state : Int64) -> Int64 {
  (state * lcg_mul + lcg_add) & lcg_mask
}

///|
/// 把 LCG 状态映射到 [0, 1) 的均匀分布。
pub fn lcg_unit(state : Int64) -> Double {
  state.to_double() / lcg_denom
}

///|
/// 造一个「闭包持有状态」的随机源：每次调用推进 LCG 并返回 [0,1)。
///
/// 用 `Ref` 而不是全局变量，是为了让多个策略实例互不干扰、
/// 且同一实例的调用序列严格可复现。
fn make_rng(seed : Int64) -> () -> Double {
  // 种子为 0 会让 LCG 退化成常数序列，替换成 1
  let state = Ref(if seed == 0L { 1L } else { seed })
  fn() {
    state.val = lcg_next(state.val)
    lcg_unit(state.val)
  }
}

// ---------------------------------------------------------------------------
// 配置与结果
// ---------------------------------------------------------------------------

///|
/// 模拟配置。
pub(all) struct SimConfig {
  /// 模拟天数
  days : Int32
  /// 每天新增卡数
  new_per_day : Int32
  /// 每天最多复习数，0 = 无限
  review_limit : Int32
  /// 目标保持率（透传给调度器构造）
  desired_retention : Double
  /// 模拟用户行为：给定到期卡状态，返回评分
  grade_fn : (CardState) -> Grade
  /// 伪随机种子（固定值保证可复现）
  seed : Int64
} derive(Debug)

///|
/// 默认配置：90 天、每天 20 张、复习上限 200、realistic 策略。
pub fn SimConfig::default() -> SimConfig {
  {
    days: 90,
    new_per_day: 20,
    review_limit: 200,
    desired_retention: 0.9,
    grade_fn: optimistic_policy(),
    seed: 20240101L,
  }
}

///|
/// 单日统计。
pub(all) struct SimDay {
  /// 第几天（0 起）
  day : Int32
  /// 当天新增卡数
  new_cards : Int32
  /// 当天开始时到期的卡数
  due_cards : Int32
  /// 当天实际复习的卡数（受 review_limit 限制）
  reviewed : Int32
  /// 当天结束时的积压（到期但未复习）
  backlog : Int32
  /// 当天复习中判为"记住了"的数量（分母是 reviewed）
  retained : Int32
} derive(Debug)

///|
/// 模拟结果。
pub(all) struct SimResult {
  days : Array[SimDay]
  total_reviews : Int32
  max_backlog : Int32
  final_backlog : Int32
} derive(Debug)

// ---------------------------------------------------------------------------
// 评分策略
// ---------------------------------------------------------------------------

///|
/// 从 CardState 估「此刻」的可提取性。
///
/// ⚠️ **这是本模拟器最容易写错的地方，值得说清楚**：
///
/// `grade_fn` 的签名是 `(CardState) -> Grade`（契约如此），它**拿不到
/// 调度器实例**，也拿不到"现在是第几天"。因此我们无法直接调用
/// `Scheduler::retrievability(state, now)`——那是唯一精确的做法。
///
/// 唯一能从 `CardState` 读出的时间量是 `due`（下次到期时刻）。
/// 一次复习发生在 `due` 附近时，"距上次复习的天数" 约等于
/// `interval_days`，于是 `R ≈ forgetting_curve(interval_days, stability)`。
///
/// **关键限制（必须在结论里说明）**：这个近似**看不见逾期**。
/// 如果卡片积压了 30 天，真实 R 早已远低于 0.9，但这里仍算 0.9。
/// 后果是「积压不会让记住率恶化」，因此模拟出的积压是**乐观下界**：
/// 真实场景里积压会自我强化（越拖越忘 → 越多 Again → 间隔回退 → 更需要复习）。
/// 想得到悲观上界，用 `pessimistic` 策略（成功概率再乘 0.7）。
///
/// 对 FSRS 这个近似相当准（它的间隔本就由 S 反解，R(I,S)=desired_retention）；
/// 对 SM-2 / Leitner 由于 stability 只是 interval 的镜像，退化成一个常数，
/// 此时策略等价于"固定成功率的伯努利抽样"——仍然可用，只是没有难度区分度。
fn policy_retrievability(cs : CardState) -> Double {
  if cs.stability <= 0.0 {
    // 新卡（还没建立记忆）：默认能答对
    return 0.9
  }
  let elapsed = if cs.interval_days > 0.0 { cs.interval_days } else { 0.0 }
  forgetting_curve(elapsed, cs.stability)
}

///|
/// optimistic：总是 Good。
///
/// 用于"最理想情况"基线：如果用户每次都答对，负载曲线长什么样。
pub fn optimistic_policy() -> (CardState) -> Grade {
  fn(_cs) { Good }
}

///|
/// realistic：以 retrievability 为"成功回忆"的概率抽样。
///
/// 抽样流程：
///   1. 用遗忘曲线算出此刻的 R
///   2. 抽 u ~ U[0,1)；u < R 则判为记住，否则判为 Again
///   3. 记住时再按 R 的高低细分 Hard / Good / Easy
///      —— R 高说明记得很牢（Easy），R 一般给 Good，勉强记住给 Hard
///
/// 这样长期看，实际保留率会收敛到目标保持率附近，是真实的用户行为模型。
pub fn realistic_policy(seed : Int64) -> (CardState) -> Grade {
  let next_u = make_rng(seed)
  fn(cs) {
    let r = policy_retrievability(cs)
    let u = next_u()
    if u < r {
      if r > 0.95 {
        Easy
      } else if r > 0.85 {
        Good
      } else {
        Hard
      }
    } else {
      Again
    }
  }
}

///|
/// pessimistic：成功概率乘以 0.7，且即便答对也偏保守（多数给 Hard）。
///
/// 用于"最坏情况"压力测试：复习量会显著上升，积压更容易出现。
pub fn pessimistic_policy(seed : Int64) -> (CardState) -> Grade {
  let next_u = make_rng(seed)
  fn(cs) {
    let r = policy_retrievability(cs) * 0.7
    let u = next_u()
    if u < r {
      if u < r * 0.3 {
        Good
      } else {
        Hard
      }
    } else {
      Again
    }
  }
}

///|
/// 按名字取评分策略。未知名字退回 optimistic。
///
/// 使用固定的默认种子，保证 CLI 不传 --seed 时仍可复现。
pub fn grade_policy(name : StringView) -> (CardState) -> Grade {
  let key = name.to_owned().to_lower()
  if key == "realistic" {
    realistic_policy(20240101L)
  } else if key == "pessimistic" {
    pessimistic_policy(667788L)
  } else {
    optimistic_policy()
  }
}

///|
/// 带显式种子的策略工厂（模拟器与测试用）。
pub fn grade_policy_with_seed(
  name : StringView,
  seed : Int64,
) -> (CardState) -> Grade {
  let key = name.to_owned().to_lower()
  if key == "realistic" {
    realistic_policy(seed)
  } else if key == "pessimistic" {
    pessimistic_policy(seed)
  } else {
    optimistic_policy()
  }
}

///|
/// 名字是否是受支持的评分策略（供 CLI 做用法校验）。
pub fn grade_policy_valid(name : StringView) -> Bool {
  let key = name.to_owned().to_lower()
  key == "optimistic" || key == "realistic" || key == "pessimistic"
}

// ---------------------------------------------------------------------------
// 模拟主体
// ---------------------------------------------------------------------------

///|
/// 第 `day` 天开始时的时刻（第 0 天 = 时间原点）。
fn day_start(day : Int32) -> Timestamp {
  day.to_int64() * 86400L
}

///|
/// 用任意调度器跑一次模拟。
///
/// 每天的流程：
///   1. **新卡入场**：造 `new_per_day` 张新卡，`due = now`（当天就学）
///   2. **找到期卡**：所有 `due <= now` 的卡
///   3. **按优先级排序**：先按 due 升序（逾期最久的先复习），
///      再按 card_id 升序（打破平局，保证确定性）
///   4. **受复习上限截断**：最多处理 `review_limit` 张
///   5. **逐张复习**：调 grade_fn 拿评分，再调 scheduler.review 推进状态
///   6. **统计积压**：当天结束时仍 `due <= now` 的卡数
///
/// 注意复习上限的含义：**新卡也占用配额**（与 Anki 一致）。
/// 因此当 backlog 很大时，用户实际上连新卡都学不了——
/// 这正是"积压拖垮学习节奏"的真实机制。
pub fn[T : Scheduler] simulate_with(s : T, config : SimConfig) -> SimResult {
  let out : Array[SimDay] = []
  // 所有卡的状态。用 Array 顺序存，索引稳定，便于原地更新。
  let states : Array[CardState] = []
  let mut total_reviews = 0
  let mut max_backlog = 0
  let mut next_card_no = 0
  let mut day = 0
  while day < config.days {
    let now = day_start(day)
    // --- 1. 新卡入场 ---
    let new_today = if config.new_per_day > 0 { config.new_per_day } else { 0 }
    let mut n = 0
    while n < new_today {
      let cid = "c" + next_card_no.to_string()
      states.push(s.init(cid, now))
      next_card_no = next_card_no + 1
      n = n + 1
    }
    // --- 2. 找到期卡 ---
    let due_idx : Array[Int32] = []
    let mut i = 0
    while i < states.length() {
      if states[i].due <= now {
        due_idx.push(i)
      }
      i = i + 1
    }
    let due_cards = due_idx.length()
    // --- 3. 排序：due 升序，其次 card_id 升序 ---
    due_idx.sort_by(fn(a, b) {
      let sa = states[a]
      let sb = states[b]
      if sa.due < sb.due {
        -1
      } else if sa.due > sb.due {
        1
      } else if sa.card_id < sb.card_id {
        -1
      } else if sa.card_id > sb.card_id {
        1
      } else {
        0
      }
    })
    // --- 4. 复习上限截断 ---
    let limit = if config.review_limit > 0 && config.review_limit < due_cards {
      config.review_limit
    } else {
      due_cards
    }
    // --- 5. 逐张复习 ---
    let mut reviewed = 0
    let mut retained = 0
    let mut j = 0
    while j < limit {
      let idx = due_idx[j]
      let before = states[idx]
      // ⚠️ 关键修正：喂给 grade_fn 的不是原始状态，而是把 `interval_days`
      // 换成「真实已过天数」（now - last_review）之后的副本。
      //
      // 为什么必须这么做：`grade_fn` 拿不到 `now`，只能从 CardState 推时间。
      // 而 `interval_days` 是**调度器给出的计划间隔**，并非真实流逝的时间。
      // 当卡片被积压拖到逾期 30 天，真实 elapsed 远大于 interval_days，
      // 真实 R 早已跌破 0.9 —— 不做这层替换，策略就会误以为「刚到点、
      // 记得很牢」，于是**积压永远不会恶化记忆**，模拟出的积压偏乐观。
      //
      // 替换之后积压会自我强化：越拖越忘 → 更多 Again → 间隔回退 →
      // 更需要复习。这才是「积压拖垮学习节奏」的真实机制。
      //
      // 注意：只污染传给评分器的副本；`s.review` 仍收到原始 `before`
      // （调度器自己会按 last_review 与 now 算 elapsed，不需要外力帮忙）。
      let elapsed_real = days_between(before.last_review, now)
      let for_grading = {
        card_id: before.card_id,
        stability: before.stability,
        difficulty: before.difficulty,
        reps: before.reps,
        lapses: before.lapses,
        last_review: before.last_review,
        due: before.due,
        interval_days: elapsed_real,
        phase: before.phase,
      }
      let g = (config.grade_fn)(for_grading)
      // 记忆的判定标准：只有 Again 算遗忘（与 SM-2 的 q<3 一致）
      if g != Again {
        retained = retained + 1
      }
      states[idx] = s.review(before, g, now)
      reviewed = reviewed + 1
      total_reviews = total_reviews + 1
      j = j + 1
    }
    // --- 6. 统计积压 ---
    let mut backlog = 0
    let mut k = 0
    while k < states.length() {
      if states[k].due <= now {
        backlog = backlog + 1
      }
      k = k + 1
    }
    if backlog > max_backlog {
      max_backlog = backlog
    }
    out.push({
      day,
      new_cards: new_today,
      due_cards,
      reviewed,
      backlog,
      retained,
    })
    day = day + 1
  }
  let final_backlog = if out.length() == 0 {
    0
  } else {
    out[out.length() - 1].backlog
  }
  { days: out, total_reviews, max_backlog, final_backlog, }
}

///|
/// 运行期分发入口（CLI 用）。
pub fn simulate(s : AnyScheduler, config : SimConfig) -> SimResult {
  simulate_with(s, config)
}
