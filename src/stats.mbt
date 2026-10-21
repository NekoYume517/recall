// recall — 统计
//
// 合同：API.md 第 6 节。
//
// 两个产出：
//   1. `compute_stats`：每张卡的复习画像（次数、遗忘、间隔、保持率）
//   2. `retention_curve`：把 elapsed_days 分桶后的保持率曲线
//
// `retention_curve` 展示经验保持率。有限样本的桶值可以回升，
// 不能把理论遗忘曲线的单调性强加给观测数据。
//
// 「是否成功回忆」统一用 `types.mbt` 的 `is_recalled(g) = g != Again`
// （API.md 第 3.1 节：答错判定用 `q < 3`，即只有 Again 算答错）。
// 本文件不再定义同名函数——同包重复定义会编译失败（[4051]）。

///|
/// 单张卡的统计画像。
pub(all) struct CardStats {
  card_id : String
  /// 总复习次数（含遗忘）
  reviews : Int32
  /// 遗忘次数（判为 Again 的次数）
  lapses : Int32
  /// 平均间隔天数（日志明确记录的正间隔，或同卡前驱推导出的间隔）
  mean_interval : Double
  /// 最大间隔天数
  max_interval : Double
  /// 保持率 = 成功复习 / 总复习，范围 [0,1]
  retention_rate : Double
} derive(Debug)

///|
/// 全项目统计共用的间隔口径。日志开始可能晚于卡片首次学习，
/// 所以首条事件的显式正间隔有效；否则只能从同卡前驱回推。
/// 同一时刻的重复复习返回 Some(0)，与没有前驱的 None 区分。
fn review_interval(ev : ReviewEvent, previous : Timestamp?) -> Double? {
  if ev.elapsed_days > 0.0 {
    Some(ev.elapsed_days)
  } else {
    previous.map(fn(ts) { days_between(ts, ev.reviewed_at) })
  }
}

///|
/// 计算每张卡的统计。返回按 card_id 升序排列的数组，保证可复现。
pub fn compute_stats(log : ReviewLog) -> Array[CardStats] {
  let grouped = log.by_card()
  let ids : Array[String] = []
  for cid in grouped.keys() {
    ids.push(cid)
  }
  ids.sort()
  let out : Array[CardStats] = []
  for cid in ids {
    let events = match grouped.get(cid) {
      Some(v) => v
      None => []
    }
    let mut reviews = 0
    let mut lapses = 0
    let mut passes = 0
    let mut interval_sum = 0.0
    let mut interval_max = 0.0
    let mut previous : Timestamp? = None
    let mut samples = 0
    for ev in events {
      reviews = reviews + 1
      if ev.grade == Again {
        lapses = lapses + 1
      }
      if is_recalled(ev.grade) {
        passes = passes + 1
      }
      match review_interval(ev, previous) {
        Some(iv) => {
          samples = samples + 1
          interval_sum = interval_sum + iv
          if iv > interval_max {
            interval_max = iv
          }
        }
        None => ()
      }
      previous = Some(ev.reviewed_at)
    }
    out.push({
      card_id: cid,
      reviews,
      lapses,
      mean_interval: if samples == 0 {
        0.0
      } else {
        interval_sum / samples.to_double()
      },
      max_interval: interval_max,
      retention_rate: if reviews == 0 {
        0.0
      } else {
        passes.to_double() / reviews.to_double()
      },
    })
  }
  out
}

///|
/// 保持率曲线：把 `elapsed_days` 分成 `buckets` 个等宽桶，
/// 每桶返回 `(桶上界天数, 该桶的保持率)`。
///
/// 设计细节：
/// - 同卡无前驱且 elapsed_days=0 的事件不参与；显式正间隔仍有效。
/// - 重复复习的零间隔参与统计；全部间隔为零时返回上界为 0 的一个桶。
/// - 桶宽 = 最大 elapsed / buckets，让最后一桶恰好覆盖最大值。
/// - 只返回**非空桶**，按桶上界升序——空桶画不出曲线，掺进去只会误导。
///
/// 这是观测保持率，有限样本不保证单调性。
pub fn retention_curve(
  log : ReviewLog,
  buckets : Int32,
) -> Array[(Double, Double)] {
  let n_buckets = if buckets < 1 { 1 } else { buckets }
  // 先按卡片和时间提取一次样本，分桶时不再重复推导前驱。
  let samples : Array[(Double, Grade)] = []
  let grouped = log.by_card()
  let ids : Array[String] = []
  for cid in grouped.keys() {
    ids.push(cid)
  }
  ids.sort()
  let mut max_elapsed = 0.0
  for cid in ids {
    let events = grouped[cid]
    let mut previous : Timestamp? = None
    for ev in events {
      match review_interval(ev, previous) {
        Some(iv) => {
          samples.push((iv, ev.grade))
          if iv > max_elapsed {
            max_elapsed = iv
          }
        }
        None => ()
      }
      previous = Some(ev.reviewed_at)
    }
  }
  if samples.length() == 0 {
    return []
  }
  if max_elapsed == 0.0 {
    let mut successes = 0
    for (_, grade) in samples {
      if is_recalled(grade) {
        successes = successes + 1
      }
    }
    return [(0.0, successes.to_double() / samples.length().to_double())]
  }
  // --- 2. 定桶宽 ---
  let width = max_elapsed / n_buckets.to_double()
  let safe_width = if width <= 0.0 { 1.0 } else { width }
  let totals = Array::make(n_buckets, 0)
  let passes = Array::make(n_buckets, 0)
  for (iv, grade) in samples {
    // 归桶：floor(iv / width)，封顶到最后一桶
    // （iv == max_elapsed 时除法得 n_buckets，必须夹回来）
    let mut bi = (iv / safe_width).to_int()
    if bi < 0 {
      bi = 0
    }
    if bi >= n_buckets {
      bi = n_buckets - 1
    }
    totals[bi] = totals[bi] + 1
    if is_recalled(grade) {
      passes[bi] = passes[bi] + 1
    }
  }
  // --- 3. 组装非空桶 ---
  let out : Array[(Double, Double)] = []
  let mut i = 0
  while i < n_buckets {
    if totals[i] > 0 {
      let upper = safe_width * (i + 1).to_double()
      out.push((upper, passes[i].to_double() / totals[i].to_double()))
    }
    i = i + 1
  }
  out
}

///|
/// 汇总后的整体指标（`stats` 子命令的页脚用）。
pub(all) struct OverallStats {
  cards : Int32
  reviews : Int32
  lapses : Int32
  /// 整体保持率 = (总复习 − 总遗忘) / 总复习
  retention_rate : Double
  /// 平均间隔（所有卡片 mean_interval 的算术平均）
  mean_interval : Double
} derive(Debug)

///|
/// 从卡片统计聚合出整体指标。
pub fn overall_stats(rows : Array[CardStats]) -> OverallStats {
  let mut reviews = 0
  let mut lapses = 0
  let mut interval_sum = 0.0
  let mut interval_n = 0
  for r in rows {
    reviews = reviews + r.reviews
    lapses = lapses + r.lapses
    if r.reviews > 1 || r.mean_interval > 0.0 {
      interval_sum = interval_sum + r.mean_interval
      interval_n = interval_n + 1
    }
  }
  {
    cards: rows.length(),
    reviews,
    lapses,
    retention_rate: if reviews == 0 {
      0.0
    } else {
      (reviews - lapses).to_double() / reviews.to_double()
    },
    mean_interval: if interval_n == 0 {
      0.0
    } else {
      interval_sum / interval_n.to_double()
    },
  }
}
