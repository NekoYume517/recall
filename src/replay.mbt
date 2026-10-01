// recall — 重放引擎
//
// 合同：API.md 第 4 节（签名已按 CONTRACT-FIX.md 修正为 AnyScheduler）。
//
// 设计要点：
// - 日志是唯一真相来源。给定日志 + 调度器，状态由重放得到，不存冗余。
// - **每张卡独立**按时间顺序重放：卡片之间互不影响，卡片内严格按
//   `reviewed_at` 升序（`ReviewLog::by_card` 已保证稳定排序）。
// - 全程确定性：卡片按 id 排序处理，浮点累加顺序固定，同输入必得同输出。
// - 泛型 `replay_with` 承载所有具体调度器；`replay` 只是 `AnyScheduler`
//   的运行期分发入口（MoonBit 没有 trait object，见 CONTRACT-FIX 方案 B）。

///|
/// 一次重放的完整结果。
pub(all) struct ReplayResult {
  /// 每张卡的最终状态（按 card_id 索引）
  final_states : Map[String, CardState]
  /// 每次事件后的状态快照：(reviewed_at, card_id, 新状态)。
  /// 顺序为「按 card_id 升序、卡片内按时间升序」，可用于逐帧对比两种调度器。
  snapshots : Array[(Timestamp, String, CardState)]
  /// 总复习次数
  total_reviews : Int32
  /// 总遗忘次数（判为 Again 的事件数）
  total_lapses : Int32
  /// 平均间隔偏差：|实际间隔 − 上次调度给出的间隔| 的均值（天）
  interval_error_days : Double
} derive(Debug)

///|
/// 用任意调度器重放整份日志。
///
/// `[T : Scheduler]` 是编译期单态化：三种调度器各自生成一份专用代码，
/// 零动态分发开销。CLI / compare 走 `replay`（AnyScheduler 分发）。
pub fn[T : Scheduler] replay_with(log : ReviewLog, s : T) -> ReplayResult {
  let final_states : Map[String, CardState] = Map([])
  let snapshots : Array[(Timestamp, String, CardState)] = []
  let grouped = log.by_card()
  // 固定卡片顺序，保证快照顺序与浮点累加顺序可复现
  let card_ids : Array[String] = []
  for cid in grouped.keys() {
    card_ids.push(cid)
  }
  card_ids.sort()
  let mut total_reviews = 0
  let mut total_lapses = 0
  let mut error_sum = 0.0
  let mut error_count = 0
  for cid in card_ids {
    let events = match grouped.get(cid) {
      Some(v) => v
      None => []
    }
    // 新卡的初始化时刻取该卡第一次复习的时刻：
    // 这样第一次复习的 elapsed 恰为 0，符合 FSRS 的"首次走初始公式"。
    let first_at = if events.length() > 0 { events[0].reviewed_at } else { 0L }
    let mut state = s.init(cid, first_at)
    let mut prev_reviewed = first_at
    let mut has_prev = false
    for ev in events {
      // 上次调度给出的间隔就是 state.interval_days（review 会覆写它，先存下来）
      let scheduled = state.interval_days
      state = s.review(state, ev.grade, ev.reviewed_at)
      // 实际间隔：优先用日志里的 elapsed_days（那是当时真实测量的值）；
      // 缺失（=0）且非首次时，按时间戳差回推。
      let actual = if ev.elapsed_days > 0.0 {
        ev.elapsed_days
      } else if has_prev {
        days_between(prev_reviewed, ev.reviewed_at)
      } else {
        0.0
      }
      // 间隔偏差只在"有上次调度"时才有意义（首次没有上一个间隔）
      if has_prev && scheduled > 0.0 {
        let diff = actual - scheduled
        error_sum = error_sum + (if diff < 0.0 { -diff } else { diff })
        error_count = error_count + 1
      }
      total_reviews = total_reviews + 1
      if ev.grade == Again {
        total_lapses = total_lapses + 1
      }
      snapshots.push((ev.reviewed_at, cid, state))
      prev_reviewed = ev.reviewed_at
      has_prev = true
    }
    final_states[cid] = state
  }
  {
    final_states,
    snapshots,
    total_reviews,
    total_lapses,
    interval_error_days: if error_count == 0 {
      0.0
    } else {
      error_sum / error_count.to_double()
    },
  }
}

///|
/// 运行期分发入口（CLI / 需要按名字选算法的地方用）。
pub fn replay(log : ReviewLog, s : AnyScheduler) -> ReplayResult {
  replay_with(log, s)
}

///|
/// 两个调度器在同一份日志上的对比结果。
pub(all) struct Comparison {
  a_name : String
  b_name : String
  a_total_interval : Double
  b_total_interval : Double
  a_lapses : Int32
  b_lapses : Int32
  /// 每张卡的最终间隔：(card_id, a 的间隔, b 的间隔)，按 card_id 升序
  per_card : Array[(String, Double, Double)]
} derive(Debug)

///|
/// 所有卡片最终间隔之和。这是"三个月后平均每张卡能撑多久"的代理指标：
/// 间隔越长，同样保持率下所需复习次数越少。
fn total_interval(res : ReplayResult) -> Double {
  let ids : Array[String] = []
  for cid in res.final_states.keys() {
    ids.push(cid)
  }
  ids.sort()
  let mut sum = 0.0
  for cid in ids {
    let v = match res.final_states.get(cid) {
      Some(st) => st.interval_days
      None => 0.0
    }
    sum = sum + v
  }
  sum
}

///|
/// 对比两个调度器。
pub fn compare(
  log : ReviewLog,
  a : AnyScheduler,
  b : AnyScheduler,
) -> Comparison {
  let ra = replay_with(log, a)
  let rb = replay_with(log, b)
  // 用 a 的卡片集合为基准（b 必然相同，因为调度器不影响日志）
  let ids : Array[String] = []
  for cid in ra.final_states.keys() {
    ids.push(cid)
  }
  ids.sort()
  let per_card : Array[(String, Double, Double)] = []
  for cid in ids {
    let va = match ra.final_states.get(cid) {
      Some(st) => st.interval_days
      None => 0.0
    }
    let vb = match rb.final_states.get(cid) {
      Some(st) => st.interval_days
      None => 0.0
    }
    per_card.push((cid, va, vb))
  }
  {
    a_name: a.name(),
    b_name: b.name(),
    a_total_interval: total_interval(ra),
    b_total_interval: total_interval(rb),
    a_lapses: ra.total_lapses,
    b_lapses: rb.total_lapses,
    per_card,
  }
}
