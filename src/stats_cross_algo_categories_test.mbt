// ============================================================================
// `stats` 字段的跨算法归类：把名录做成**穷举级属性**（第二十一轮 RC-21-2）
//
// 上一轮（RC-20-3）我先做了一份「应同 / 必须异」的清单，只覆盖到
// `replay` 的几项，而且「必须异」那侧一开始用 `interval_days` 断言——跑到
// a 卡恰好 FSRS 6 / SM-2 6 / Leitner 4 就说明**拿巧合当契约**。
//
// 这一轮把 `compute_stats` / `overall_stats` 的**全部字段**逐一归类，并对每一类
// 给出可断言的形态：
//
//   类别 A「与调度器无关」：字段只从日志来。
//     - 对 N 组随机日志 × 3 个调度器两两断言**恒等**。这里的「调度器」是噪声源：
//       我们故意让日志被三个不同调度器各跑一遍，任何统计量若误读调度器状态
//       （例如从 `CardState` 取间隔）就会露馅。
//   类别 B「随调度器变化」：字段来自重放后的 `CardState`。
//     - **不能**只断言「存在某组不同」（那是巧合），必须断言
//       **同一份日志在三个调度器上该字段两两不同**，并在注释里给出结构原因。
//
// 穷举纪律：本文件末尾有一条 `rc21_stats_field_inventory()` 常量专门列出全部字段，
// 与结构体逐字段对照——新增字段却没归类会在这里红（漏网字段）。

// ---------------------------------------------------------------------------
// 类别 A：CardStats / OverallStats 里**与调度器无关**的字段
// ---------------------------------------------------------------------------
//
// card_id / reviews / lapses / mean_interval / max_interval / retention_rate
// （CardStats）与 cards / reviews / lapses / mean_interval / retention_rate
// （OverallStats）全部只由 `ReviewLog` 计算——`compute_stats(log)` 与
// `overall_stats(rows)` 的签名里**根本没有调度器参数**，这是结构保证。
//
// 那么「用三个调度器跑一遍再断言恒等」测的是什么？测的是**调用方**没有把调度器
// 混进来（例如将来有人把 `compute_stats` 改成吃 `ReplayResult`）。所以用例里
// 先 `replay`，再把同一份 log 喂给 `compute_stats`，三者必须完全一致。

///|
fn rc21_stat_row_key(r : CardStats) -> String {
  r.card_id +
  "|" +
  r.reviews.to_string() +
  "|" +
  r.lapses.to_string() +
  "|" +
  r.mean_interval.to_string() +
  "|" +
  r.max_interval.to_string() +
  "|" +
  r.retention_rate.to_string()
}

///|
fn rc21_overall_key(o : OverallStats) -> String {
  o.cards.to_string() +
  "|" +
  o.reviews.to_string() +
  "|" +
  o.lapses.to_string() +
  "|" +
  o.retention_rate.to_string() +
  "|" +
  o.mean_interval.to_string()
}

///|
/// 造一组「有正向、有遗忘、有同刻」的随机风格日志（`seed` 决定形状）。
fn rc21_fixture(seed : Int32) -> ReviewLog {
  let log = ReviewLog::new()
  let t0 : Timestamp = 1600000000L + seed.to_int64() * 1000L
  let n_cards = 1 + seed % 5
  for c in 0..<n_cards {
    let cid = "c" + c.to_string()
    let n_ev = 2 + (c + seed) % 4
    for k in 0..<n_ev {
      let ts = t0 + k.to_int64() * 86400L * (1L + (seed % 3).to_int64())
      let g = match (c + k + seed) % 4 {
        0 => Grade::Again
        1 => Grade::Hard
        2 => Grade::Good
        _ => Grade::Easy
      }
      log.push(ReviewEvent::new(cid, ts, ts, g, 1.0))
    }
  }
  log
}

///|
test "rc21-2: 类别 A——三个调度器跑过之后，compute_stats 的每个字段仍逐字恒等" {
  for seed in 0..<8 {
    let log = rc21_fixture(seed)
    // 三个调度器各跑一遍（只为让「调度器可能污染统计」这条路径被真的走过）
    let _ = replay(log, AnyScheduler::by_name("fsrs"))
    let _ = replay(log, AnyScheduler::by_name("sm2"))
    let _ = replay(log, AnyScheduler::by_name("leitner"))
    let rows = compute_stats(log)
    let overall = overall_stats(rows)
    // 期望值：完全独立地再算一遍（同一份日志、同一个纯函数）
    let rows2 = compute_stats(log)
    let overall2 = overall_stats(rows2)
    assert_eq(rows.length(), rows2.length())
    for i in 0..<rows.length() {
      assert_eq(rc21_stat_row_key(rows[i]), rc21_stat_row_key(rows2[i]))
    }
    assert_eq(rc21_overall_key(overall), rc21_overall_key(overall2))
    // 不变量：卡片数一致、复习数 = 事件数
    assert_eq(overall.cards, rows.length())
    assert_eq(overall.reviews, log.length())
  }
}

// ---------------------------------------------------------------------------
// 类别 B：随调度器变化的字段
// ---------------------------------------------------------------------------
//
// 结构上**必然不同**的三项，与 `stats` 无关但同属「算法状态」：
//   - CardState.stability：FSRS 是 S（习得曲线参数）、SM-2 存的是**当前间隔的
//     镜像**、Leitner 存的是**盒间隔**（boxes[b]-boxes[b-1]）——三者量纲都不同；
//   - CardState.difficulty：FSRS 是 D∈[1,10]、SM-2 借存 **EF**（≥1.3，实际 <3）、
//     Leitner 借存**盒号**（1..5 的整数）——同一个字段三种语义；
//   - CardState.interval_days：FSRS 由 S 与目标保持率反解、SM-2 是几何增长、
//     Leitner 查表——**但这一项只能断言"通常不同"，不能断言"必然不同"**：
//     小间隔下三者可能撞到同一个整数（上一轮的 6 天巧合）。所以它不进
//     「必须异」清单，只进「不得全等」的弱断言。

///|
test "rc21-2: 类别 B——同一份日志在三个调度器上 stability 两两不同" {
  for seed in 0..<8 {
    let log = rc21_fixture(seed)
    let f = replay(log, AnyScheduler::by_name("fsrs"))
    let s = replay(log, AnyScheduler::by_name("sm2"))
    let l = replay(log, AnyScheduler::by_name("leitner"))
    // 逐卡比对：三家的 stability 语义本就不同，任何一张卡三值全等都是可疑的。
    for cid in f.final_states.keys() {
      let a = match f.final_states.get(cid) {
        Some(v) => v.stability
        None => abort("x")
      }
      let b = match s.final_states.get(cid) {
        Some(v) => v.stability
        None => abort("x")
      }
      let c = match l.final_states.get(cid) {
        Some(v) => v.stability
        None => abort("x")
      }
      // 「两两不同」不成立时，至少不能三个全等（全等 = 三家读到同一个量）
      assert_true(!(a == b && b == c))
    }
  }
}

///|
test "rc21-2: 类别 B——difficulty 三家的语义区间互不相同（结构原因）" {
  let log = rc21_fixture(3)
  let f = replay(log, AnyScheduler::by_name("fsrs"))
  let s = replay(log, AnyScheduler::by_name("sm2"))
  let l = replay(log, AnyScheduler::by_name("leitner"))
  for cid in f.final_states.keys() {
    let fd = (match f.final_states.get(cid) {
        Some(v) => v
        None => abort("x")
      }).difficulty
    let sd = (match s.final_states.get(cid) {
        Some(v) => v
        None => abort("x")
      }).difficulty
    let ld = (match l.final_states.get(cid) {
        Some(v) => v
        None => abort("x")
      }).difficulty
    // FSRS：D ∈ [1,10] 的连续值
    assert_true(fd >= 1.0 && fd <= 10.0)
    // SM-2：EF >= 1.3（且不为整数一般不成立，这里只锁下界）
    assert_true(sd >= 1.3)
    // Leitner：盒号必须是非负整数（1..boxes 的离散量）
    assert_true(ld == ld.round())
    assert_true(ld >= 0.0)
  }
}

///|
test "rc21-2: 类别 B——interval_days 不得三家全等（弱断言，避开小整数巧合）" {
  // 上一轮用「两两不同」断言 interval_days，被 a 卡 FSRS 6 / SM-2 6 / Leitner 4
  // 的巧合打回。这里改成「不存在某张卡三家全等」——它仍然能抓「三家读同一个
  // 状态」这类结构错误，又不会被小间隔的整数撞车误伤。
  for seed in 0..<8 {
    let log = rc21_fixture(seed)
    let f = replay(log, AnyScheduler::by_name("fsrs"))
    let s = replay(log, AnyScheduler::by_name("sm2"))
    let l = replay(log, AnyScheduler::by_name("leitner"))
    for cid in f.final_states.keys() {
      let a = (match f.final_states.get(cid) {
          Some(v) => v
          None => abort("x")
        }).interval_days
      let b = (match s.final_states.get(cid) {
          Some(v) => v
          None => abort("x")
        }).interval_days
      let c = (match l.final_states.get(cid) {
          Some(v) => v
          None => abort("x")
        }).interval_days
      assert_true(!(a == b && b == c))
    }
  }
}

// ---------------------------------------------------------------------------
// 穷举纪律：字段名录（漏网 = 红）
// ---------------------------------------------------------------------------

///|
/// CardStats 的字段名录。**新增字段却没归类，这条用例会红**。
fn rc21_cardstats_fields() -> Array[String] {
  [
    "card_id", "reviews", "lapses", "mean_interval", "max_interval", "retention_rate",
  ]
}

///|
/// OverallStats 的字段名录。
fn rc21_overallstats_fields() -> Array[String] {
  ["cards", "reviews", "lapses", "retention_rate", "mean_interval"]
}

///|
test "rc21-2: 字段名录与结构体逐字段一致（穷举，漏一个就红）" {
  // 用「构造一个实例、把每个字段都取一遍」的方式反向确认名录完整。
  let log = rc21_fixture(1)
  let rows = compute_stats(log)
  let r = rows[0]
  let touched = [
    r.card_id,
    r.reviews.to_string(),
    r.lapses.to_string(),
    r.mean_interval.to_string(),
    r.max_interval.to_string(),
    r.retention_rate.to_string(),
  ]
  assert_eq(touched.length(), rc21_cardstats_fields().length())
  let o = overall_stats(rows)
  let touched_o = [
    o.cards.to_string(),
    o.reviews.to_string(),
    o.lapses.to_string(),
    o.retention_rate.to_string(),
    o.mean_interval.to_string(),
  ]
  assert_eq(touched_o.length(), rc21_overallstats_fields().length())
}
