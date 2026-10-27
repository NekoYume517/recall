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
/// 每桶返回 `(桶下界天数, 桶上界天数, 该桶的保持率)`。
///
/// 分桶语义：**左闭右开 `[lo, hi)`**，`bi = floor(iv / width)`。
/// 返回值同时给出上下界，标签才与桶内容一致——旧实现只回上界，
/// CLI 把它打印成 `< hi`，读起来像「所有小于 hi 的样本」，于是
/// elapsed 恰好等于某桶下界的样本会显示在比直觉高一档的标签下。
/// `elapsed == max_elapsed` 时除法得 `n_buckets`，夹进最后一桶，
/// 因此最后一桶实际是 `[lo, hi]`（闭区间，覆盖最大值）。
///
/// 设计细节：
/// - 同卡无前驱且 elapsed_days=0 的事件不参与；显式正间隔仍有效。
/// - 重复复习的零间隔参与统计；全部间隔为零时返回一个 `[0, 0]` 的桶。
/// - 桶宽 = 最大 elapsed / buckets，让最后一桶恰好覆盖最大值。
/// - 只返回**非空桶**，按桶下界升序——空桶画不出曲线，掺进去只会误导。
///
/// 这是观测保持率，有限样本不保证单调性。
pub fn retention_curve(
  log : ReviewLog,
  buckets : Int32,
) -> Array[(Double, Double, Double)] {
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
    return [(0.0, 0.0, successes.to_double() / samples.length().to_double())]
  }
  // --- 2. 定桶宽 ---
  let width = max_elapsed / n_buckets.to_double()
  let safe_width = if width <= 0.0 { 1.0 } else { width }
  let totals = Array::make(n_buckets, 0)
  let passes = Array::make(n_buckets, 0)
  for (iv, grade) in samples {
    // 归桶：用**与标签同源**的乘法边界比较（RC-8，2026-10-27）。
    //
    // 旧实现是 `bi = (iv / width).to_int()`（除法），标签是
    // `width * i`（乘法）。两套算式在桶沿上打架：对 iv = max/n * k
    // 这类数学上正好落在桶沿的样本，`iv / width` 会比整数小 1~2 ulp，
    // 截断后掉进**前一桶**，于是打印出的 `[lo, hi)` 上界恰好等于该样本，
    // 记号自相矛盾。
    //
    // 精确见证（max=180, buckets=7, width=180/7=25.714285714285715）：
    //   iv = 180*3/7       = 77.14285714285714
    //   iv / width         = 2.9999999999999996   → to_int = 2（旧：落桶 2）
    //   width * 3          = 77.14285714285714     ← 与 iv 逐位相同
    // 穷举扫描命中 583 组。现在归桶直接与标签用同一串 `width * k` 比较，
    // 于是「标签含自己桶内样本」成为构造保证。
    //
    // 语义：找最大的 k 使 `iv >= width*k`（等价于 `k = ceil(iv/width)-1`），
    // 再封顶到最后一桶（iv == max_elapsed 时落在末桶，末桶是闭区间）。
    let mut bi = 0
    while bi + 1 < n_buckets && iv >= safe_width * (bi + 1).to_double() {
      bi = bi + 1
    }
    totals[bi] = totals[bi] + 1
    if is_recalled(grade) {
      passes[bi] = passes[bi] + 1
    }
  }
  // --- 3. 组装非空桶 ---
  let out : Array[(Double, Double, Double)] = []
  let mut i = 0
  while i < n_buckets {
    if totals[i] > 0 {
      // 上下界仍用与归桶相同的 `width * k` 乘出来：
      // 相邻桶严格首尾相接，且与归桶比较逐位同源。
      let lower = safe_width * i.to_double()
      let upper = safe_width * (i + 1).to_double()
      out.push((lower, upper, passes[i].to_double() / totals[i].to_double()))
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
  /// 有间隔样本的卡片 mean_interval 的等权平均，无样本卡片不计入。
  /// 首条显式正间隔有效；同刻重复复习的零间隔也有效。
  mean_interval : Double
} derive(Debug)

///|
/// 从 `compute_stats` 生成的卡片统计聚合整体指标。
/// 有样本卡片判据为 reviews > 1 或 mean_interval > 0；空样本整体均值为 0。
/// 若自行构造 CardStats，应保留相同的计数与间隔约定。
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
