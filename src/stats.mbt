// recall — 统计
//
// 合同：API.md 第 6 节。
//
// 两个产出：
//   1. `compute_stats`：每张卡的复习画像（次数、遗忘、间隔、保持率）
//   2. `retention_curve`：把 elapsed_days 分桶后的保持率曲线
//
// `retention_curve` 是整个项目的**合理性检验点**：
// 间隔越长，遗忘越多，因此保持率必须随 elapsed 单调下降。
// 这条属性写成了测试，任何公式写错都会在这里暴露。
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
  /// 平均间隔天数（只统计"有上一次复习"的样本，首次不计）
  mean_interval : Double
  /// 最大间隔天数
  max_interval : Double
  /// 保持率 = 成功复习 / 总复习，范围 [0,1]
  retention_rate : Double
} derive(Debug)

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
    let mut prev_ts : Timestamp = 0L
    let mut has_prev = false
    for ev in events {
      reviews = reviews + 1
      if ev.grade == Again {
        lapses = lapses + 1
      }
      if is_recalled(ev.grade) {
        passes = passes + 1
      }
      // 间隔：优先用日志里的 elapsed_days（当时真实测量值）；
      // 缺失（=0）且非首次时按时间戳差回推。
      let iv = if ev.elapsed_days > 0.0 {
        ev.elapsed_days
      } else if has_prev {
        days_between(prev_ts, ev.reviewed_at)
      } else {
        0.0
      }
      if has_prev {
        interval_sum = interval_sum + iv
        if iv > interval_max {
          interval_max = iv
        }
      }
      prev_ts = ev.reviewed_at
      has_prev = true
    }
    // 首次复习没有"间隔"，所以分母是 reviews - 1
    let samples = if reviews > 1 { reviews - 1 } else { 0 }
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
/// - **首次复习（elapsed_days = 0）不参与**：没有间隔就没有"保持"可言。
/// - 桶宽 = 最大 elapsed / buckets，让最后一桶恰好覆盖最大值。
/// - 只返回**非空桶**，按桶上界升序——空桶画不出曲线，掺进去只会误导。
///
/// 理论保证：保持率随桶上界上升而**单调不增**。这是测试的核心断言。
pub fn retention_curve(
  log : ReviewLog,
  buckets : Int32,
) -> Array[(Double, Double)] {
  let n_buckets = if buckets < 1 { 1 } else { buckets }
  // --- 1. 找最大 elapsed 与样本数 ---
  let mut max_elapsed = 0.0
  let mut sample_count = 0
  for ev in log.events {
    if ev.elapsed_days > 0.0 {
      if ev.elapsed_days > max_elapsed {
        max_elapsed = ev.elapsed_days
      }
      sample_count = sample_count + 1
    }
  }
  if sample_count == 0 || max_elapsed <= 0.0 {
    return []
  }
  // --- 2. 定桶宽 ---
  let width = max_elapsed / n_buckets.to_double()
  let safe_width = if width <= 0.0 { 1.0 } else { width }
  let totals = Array::make(n_buckets, 0)
  let passes = Array::make(n_buckets, 0)
  for ev in log.events {
    if ev.elapsed_days <= 0.0 {
      continue
    }
    // 归桶：floor(elapsed / width)，封顶到最后一桶
    // （elapsed == max_elapsed 时除法得 n_buckets，必须夹回来）
    let mut bi = (ev.elapsed_days / safe_width).to_int()
    if bi < 0 {
      bi = 0
    }
    if bi >= n_buckets {
      bi = n_buckets - 1
    }
    totals[bi] = totals[bi] + 1
    if is_recalled(ev.grade) {
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
    if r.reviews > 1 {
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
