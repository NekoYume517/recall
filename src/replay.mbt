// recall — 重放引擎
//
// 合同：API.md 第 4 节（签名已按 CONTRACT-FIX.md 修正为 AnyScheduler）。
//
// 设计要点：
// - 日志是唯一真相来源。给定日志 + 调度器，状态由重放得到，不存冗余。
// - **每张卡独立**按时间顺序重放：卡片之间互不影响，卡片内严格按
//   `reviewed_at` 升序（`ReviewLog::by_card` 已保证稳定排序）。
// - 全程确定性：卡片按 id 排序处理，浮点累加顺序固定，同输入必得同输出。
//   **边界**（第二十轮 RC-20-3）：这里说的「同输入」是「同一份文件」——同一张卡、
//   同一秒的两条不同事件换个文件行序，终态会变（`by_card` 的相等分支返回 -1 让
//   比较器自相矛盾；缺 elapsed_days 的事件又靠「上一条」回推）。同刻先后的业务
//   含义在日志里没有字段可依据，所以本轮**不修语义**，只把边界写成可执行断言
//   （src/replay_tie_order_boundary_test.mbt）并记进 API.md §17 的确定性条款。
// - 泛型 `replay_with` 承载所有具体调度器；`replay` 只是 `AnyScheduler`
//   的运行期分发入口（MoonBit 没有 trait object，见 CONTRACT-FIX 方案 B）。

///|
/// 一次重放的完整结果。
#derive(Debug)
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
  /// **带符号**的平均间隔偏差：(`实际间隔 − 上次调度给出的间隔`) 的均值（天）。
  /// 逾期为正、提前为负，与 `interval_error_days` 覆盖同一批样本
  /// （第十九轮 RC-19-2：绝对值统计量看不见方向，"抵平"会被报成 4 天偏差）。
  signed_interval_error_days : Double
  /// 逾期复习占比 = 「实际间隔 > 上次计划间隔」的样本数 / 有间隔样本数。
  /// 无样本时为 0。落在 [0,1]。
  late_review_ratio : Double
  /// **有同刻事件的卡片数**（同一 card 内至少两条 `reviewed_at` 相等）。
  ///
  /// 为什么要有这个字段（第二十轮 RC-20-3 追加）：同刻事件的先后**由文件行序
  /// 决定**——缺 `elapsed_days` 的事件按「上一条」回推间隔，`by_card` 的稳定排序
  /// 又保留输入顺序，于是同一批数据换个行序会得出不同终态（实测 2.0 vs 6.0）。
  /// 这条边界此前只写在 API.md 里，而 `--json` 的使用者读的是 stdout/stderr。
  ///
  /// 口径：按 `by_card` 分好组、组内按 `reviewed_at` 稳定排序后，数「相邻两条
  /// 时间戳相等」的卡片数（每张卡最多计 1，哪怕有 3 条同刻）。它是**日志属性**，
  /// 与调度器无关（三个调度器必须给出同一个数）。
  same_timestamp_groups : Int32
}

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
  card_ids.sort_by(fn(a, b) { a.lexical_compare(b) })
  let mut total_reviews = 0
  let mut total_lapses = 0
  // 均值用增量式（第十二轮审计，P2）：`elapsed_days` 只要有限就收，
  // 于是 1e308 这类合法输入会把 `error_sum` 加成 +Inf，`interval_error_days`
  // 变成 Infinity（CLI 打出来不是合法 JSON）。中间量恒落在 [0, max] 内。
  let mut error_mean = 0.0
  let mut error_count = 0
  // 带符号的偏差均值，与上面同族、同一批样本（第十九轮 RC-19-2）。
  // `interval_error_days` 是 |实际 − 计划|，方向无关；保守与激进两种调度
  // 错误因此混在同一个非负数字里。这个字段保留方向：逾期为正、提前为负。
  let mut signed_mean = 0.0
  let mut late_count = 0
  // 同一 card 内有 ≥2 条相同时刻事件 → 计一张「同刻卡」（第二十轮 RC-20-3）。
  // 计在卡片层而不是事件层：告警要说的是「这张卡的摘要可能随行序变」。
  let mut same_ts_cards = 0
  for cid in card_ids {
    let events = match grouped.get(cid) {
      Some(v) => v
      None => []
    }
    // 新卡的初始化时刻取该卡第一次复习的时刻：
    // 这样第一次复习的 elapsed 恰为 0，符合 FSRS 的"首次走初始公式"。
    let first_at = if events.length() > 0 { events[0].reviewed_at } else { 0L }
    // 同刻检测：events 已按 `reviewed_at` 稳定排序，相邻两条相等即成一组。
    let mut tied = false
    for i = 1; i < events.length(); i = i + 1 {
      if events[i].reviewed_at == events[i - 1].reviewed_at {
        tied = true
        break
      }
    }
    if tied {
      same_ts_cards = same_ts_cards + 1
    }
    let mut state = s.init(cid, first_at)
    let mut prev_reviewed = first_at
    let mut has_prev = false
    for ev in events {
      // **上次调度给出的间隔**取日志里的 `due_at`（第十九轮 RC-19-2）。
      //
      // 旧实现取 `state.interval_days`——那是**重放到此刻的调度器自己算出的**
      // 间隔，于是 `actual − scheduled` 恒等于「日志的实际间隔 − 调度器的理想
      // 间隔」，`due_at` 一个字节都没参与：只把 `due_at` 挪 ±4 天，读数一动不动
      // （实测恒等 2.00 天）。而结构体注释与 API.md 写的都是「上次调度给出的
      // 间隔」，读者理解成 `due_at` 才是自然的。
      //
      // 新口径：`scheduled = (due_at − 上一条 reviewed_at) / 86400`，负数按 0
      // 处理（`due_at` 早于上次复习 = 计划已过期，等价于"当天就该复习了"）。
      // 首条事件没有前驱，只能用调度器初始化状态（日志里没有更早的计划值）。
      let scheduled = if has_prev {
        let planned = days_between(prev_reviewed, ev.due_at)
        if planned > 0.0 {
          planned
        } else {
          0.0
        }
      } else {
        state.interval_days
      }
      // ⚠️ 这里必须**自己记录**上一条事件的时间戳：`ReviewEvent::new` 会把
      // 间隔 < 1 天的 `due_at` 夹到 `reviewed_at`（等价「当天到期」），因此
      // `prev_reviewed` 只能来自日志原文，不能用夹取后的计划值。
      state = s.review(state, ev.grade, ev.reviewed_at)
      // 实际间隔：优先用日志里**有限且 > 0** 的 elapsed_days（那是当时真实
      // 测量的值）；否则按同卡前驱时间戳回推。
      //
      // 判据与 `stats.review_interval`、`ReviewEvent::new` 的写出口（`0`）
      // 以及 API.md §2 的全局口径逐字一致：`+Infinity` 不进入均值。
      // 修复前这里只判 `> 0.0`，`ReviewEvent::new(..., +Infinity)` 会被当成
      // 样本 → `diff = Infinity - scheduled = Infinity`，再叠一条有限样本时
      // 增量均值执行 `Infinity - Infinity` **变 NaN**；同一日志落盘（写 0）
      // 再读回重放却是有限的回推值——`log.mbt` 声明的往返一致性因此破裂。
      let explicit_ok = ev.elapsed_days > 0.0 && ev.elapsed_days != 1.0 / 0.0
      let actual = if explicit_ok {
        ev.elapsed_days
      } else if has_prev {
        days_between(prev_reviewed, ev.reviewed_at)
      } else {
        0.0
      }
      // 间隔偏差只在"有上次调度"且该间隔本身有限时才成立；+
      // `pub(all) CardState` 的手工状态可以带 Infinity/NaN 进来（API §6
      // 把 replay 纳入「均值不溢出」不变量），非有限间隔直接不计样本。
      if has_prev && scheduled > 0.0 && scheduled != 1.0 / 0.0 {
        let diff = actual - scheduled
        let abs_diff = if diff < 0.0 { -diff } else { diff }
        error_count = error_count + 1
        error_mean = error_mean +
          (abs_diff - error_mean) / error_count.to_double()
        signed_mean = signed_mean +
          (diff - signed_mean) / error_count.to_double()
        // 逾期判据与 `CardState::overdue_days` 同符号：实际 > 计划即逾期。
        if diff > 0.0 {
          late_count = late_count + 1
        }
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
      error_mean
    },
    signed_interval_error_days: if error_count == 0 {
      0.0
    } else {
      signed_mean
    },
    late_review_ratio: if error_count == 0 {
      0.0
    } else {
      late_count.to_double() / error_count.to_double()
    },
    same_timestamp_groups: same_ts_cards,
  }
}

///|
/// 运行期分发入口（CLI / 需要按名字选算法的地方用）。
pub fn replay(log : ReviewLog, s : AnyScheduler) -> ReplayResult {
  replay_with(log, s)
}

///|
/// 两个调度器在同一份日志上的对比结果。
///
/// `a_lapses` / `b_lapses` 是**调度器视角的间隔回退次数**（R4 修复）：
/// 重放后某次复习把 interval 从 v 压回更小值（v > 1 且新值 <= 1）计一次。
/// 旧实现数的是日志里的 Again 事件——那是**用户行为**，两个调度器读的
/// 是同一份日志，所以两列恒等、差值恒 0，而 CLI 还把它推荐为「更可比的
/// 指标」，纯属误导。注意这个指标依然偏向宽松的调度器（间隔本来就短，
/// 更难触发回退），CLI 会说明这一点。
#derive(Debug)
pub(all) struct Comparison {
  a_name : String
  b_name : String
  a_total_interval : Double
  b_total_interval : Double
  a_lapses : Int32
  b_lapses : Int32
  /// 每张卡的最终间隔：(card_id, a 的间隔, b 的间隔)，按 card_id 升序
  per_card : Array[(String, Double, Double)]
}

///|
/// 所有卡片最终间隔之和。这是"三个月后平均每张卡能撑多久"的代理指标：
/// 间隔越长，同样保持率下所需复习次数越少。
fn total_interval(res : ReplayResult) -> Double {
  let ids : Array[String] = []
  for cid in res.final_states.keys() {
    ids.push(cid)
  }
  ids.sort_by(fn(a, b) { a.lexical_compare(b) })
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
  ids.sort_by(fn(a, b) { a.lexical_compare(b) })
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
    a_name: Scheduler::name(a),
    b_name: Scheduler::name(b),
    a_total_interval: total_interval(ra),
    b_total_interval: total_interval(rb),
    a_lapses: scheduler_lapses(ra),
    b_lapses: scheduler_lapses(rb),
    per_card,
  }
}

///|
/// 调度器视角的间隔回退次数：一次复习后 interval 从 >1 天缩回 <=1 天。
///
/// 这是「这个调度器认为你忘了」的代理——SM-2 遗忘后 interval 归 1、
/// FSRS 大幅缩短间隔。与日志里的 Again 次数（用户行为，与调度器无关）
/// 是两回事。
fn scheduler_lapses(res : ReplayResult) -> Int32 {
  // 按 (card, 时间) 重放快照序列，观察 interval 的跳变
  let by_card : Map[String, Array[(Int64, Double)]] = Map([])
  for snap in res.snapshots {
    let arr = match by_card.get(snap.1) {
      Some(a) => a
      None => {
        let a : Array[(Int64, Double)] = []
        by_card[snap.1] = a
        a
      }
    }
    arr.push((snap.0, snap.2.interval_days))
  }
  let mut lapses = 0
  for cid in by_card.keys() {
    let arr = match by_card.get(cid) {
      Some(a) => a
      None => continue
    }
    // snapshots 的推进顺序即复习顺序（replay 按时间处理）
    let mut prev = -1.0
    for pair in arr {
      let cur = pair.1
      if prev > 1.0 && cur <= 1.0 {
        lapses = lapses + 1
      }
      prev = cur
    }
  }
  lapses
}
