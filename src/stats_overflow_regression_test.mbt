///|
/// 审计回归（第十二轮，P2）：`interval_sum` 类的浮点累加溢出会把
/// 「有限但极大」的合法输入算成 `Infinity`，而 `Infinity` 既不是合法 JSON
/// 也不是可读结论。
///
/// ## 现象（修复前实测，CLI）
///
/// ```
/// $ recall stats --log probe/extreme-elapsed.jsonl
/// a     3   0   Infinity   1e+308   100.00%        ← 均值 > 最大值，自相矛盾
/// 合计  3   0   Infinity            100.00%
/// $ recall replay --log probe/extreme-elapsed.jsonl --json
/// {"scheduler":"fsrs",…,"interval_error_days":Infinity,…}   ← 不是 JSON
/// ```
///
/// ## 输入是合法的
///
/// `elapsed_days = 1e308` 是**有限** Double，`log.mbt` 的 `field_double` 只拒绝
/// 非有限值（NaN / ±Infinity），所以这份日志能被解析、重放、统计 —— 缺陷在
/// 统计层把有限值加成了 `Infinity`（`1e308 + 1e308` 越过 Double 上界）。
///
/// ## 不变量
///
/// 对任意有限样本，**均值不可能超过最大值**（数学必然）。这条断言与具体
/// 数值无关，所以既不依赖机器，也不依赖浮点实现——它是本组用例的主锁。

///|
/// 极大但合法的间隔值：`1e308`（有限；两个相加才溢出）。
fn huge_iv() -> Double {
  1.0e308
}

///|
/// 一份「同卡多条、间隔 1e308」的日志。首条零间隔无前驱、不计入样本；
/// 后两条各贡献一个 1e308 的样本。
fn huge_elapsed_log() -> ReviewLog {
  let log = ReviewLog::new()
  log.push(ReviewEvent::new("a", 1000000L, 1000000L, Good, 0.0))
  log.push(ReviewEvent::new("a", 2000000L, 1000000L, Good, huge_iv()))
  log.push(ReviewEvent::new("a", 3000000L, 2000000L, Good, huge_iv()))
  log
}

///|
test "stats overflow: mean_interval 不超过 max_interval（累加不再溢出）" {
  let rows = compute_stats(huge_elapsed_log())
  inspect(rows.length(), content="1")
  let r = rows[0]
  // 修复前：mean = Infinity、max = 1e308 ⇒ 这条断言红。
  assert_true(r.mean_interval <= r.max_interval)
  // 空泛的「不是 Infinity」也锁一遍，便于红日志一眼可读。
  assert_false(r.mean_interval == 1.0 / 0.0)
  assert_false(r.max_interval == 1.0 / 0.0)
}

///|
test "stats overflow: overall_stats 的均值同样不溢出" {
  let rows = compute_stats(huge_elapsed_log())
  let overall = overall_stats(rows)
  assert_false(overall.mean_interval == 1.0 / 0.0)
  // 整体均值不可能超过单卡最大值。
  assert_true(overall.mean_interval <= rows[0].max_interval)
}

///|
test "stats overflow: replay 的 interval_error_days 不溢出" {
  let log = huge_elapsed_log()
  let res = replay(log, AnyScheduler::by_name("fsrs"))
  assert_false(res.interval_error_days == 1.0 / 0.0)
  assert_false(res.interval_error_days.is_nan())
  // 间隔偏差也不可能超过「实际间隔」本身的最大值。
  assert_true(res.interval_error_days <= huge_iv())
}

///|
test "stats overflow: 常规日志的均值逐位不变（防过度收紧）" {
  // 增量均值对可精确表示的小样本必须与「求和后相除」逐位相同。
  let log = ReviewLog::new()
  log.push(ReviewEvent::new("a", 0L, 0L, Good, 0.0))
  log.push(ReviewEvent::new("a", 86400L, 86400L, Good, 1.0))
  log.push(ReviewEvent::new("a", 172800L, 172800L, Good, 3.0))
  log.push(ReviewEvent::new("a", 259200L, 259200L, Good, 2.0))
  let rows = compute_stats(log)
  // (1 + 3 + 2) / 3 = 2.0，两种算法都逐位相同。
  inspect(rows[0].mean_interval, content="2")
  inspect(rows[0].max_interval, content="3")
}
