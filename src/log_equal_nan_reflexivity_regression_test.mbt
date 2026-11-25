// recall — ReviewEvent::equal 的自反性
//
// 现象：`ReviewEvent::equal(ev, ev)` 对 `elapsed_days = NaN` 的事件返回
// **false** —— 一个事件与自己不相等；`ReviewLog::equal(log, log)` 同样为
// false。
//
// 根因：`equal` 用 `==` 逐字段比较，浮点的 `NaN == NaN` 恒假。构造器
// `ReviewEvent::new_with_raw` 只把**负数**夹到 0，`NaN` / `±Infinity` 原样
// 进事件（API.md 第 2 节「构造器只把负数夹到 0」），因此这条路径对
// 公开 API 可达。
//
// 为什么要锁：`equal` 被 API 文档描述为「无损日志」承诺的载体，调用方用它
// 校验日志同一性（例如「重放两次结果是否一致」「读回的日志与内存里的是
// 否同一份」）。一个不自反的相等关系会让这些校验**假阴性**：两份完全相同
// 的日志被判为不同，而差异根本不存在。
//
// 修复方向：`elapsed_days` 用「同值或同为 NaN」比较；其余字段保持逐字段。

///|
test "log: ReviewEvent::equal 对 NaN elapsed_days 自反" {
  let nan = 0.0 / 0.0
  let ev = ReviewEvent::new_with_raw(
    "c1",
    1700000000L,
    1699999000L,
    Good,
    3L,
    nan,
  )
  // 事件与它自己必须相等
  assert_eq(ReviewEvent::equal(ev, ev), true)
}

///|
test "log: ReviewLog::equal 对含 NaN 事件的同一份日志自反" {
  let nan = 0.0 / 0.0
  let log = ReviewLog::new()
  log.push(
    ReviewEvent::new_with_raw("c1", 1700000000L, 1699999000L, Good, 3L, nan),
  )
  assert_eq(ReviewLog::equal(log, log), true)
}

///|
test "log: NaN elapsed_days 的两条事件逐字段相同则相等（对称）" {
  let nan = 0.0 / 0.0
  let a = ReviewEvent::new_with_raw(
    "c1",
    1700000000L,
    1699999000L,
    Good,
    3L,
    nan,
  )
  let b = ReviewEvent::new_with_raw(
    "c1",
    1700000000L,
    1699999000L,
    Good,
    3L,
    nan,
  )
  // 两条事件的所有字段都相同（NaN 也同为 NaN），应当相等
  assert_eq(ReviewEvent::equal(a, b), true)
  assert_eq(ReviewEvent::equal(b, a), true)
}

///|
test "log: NaN elapsed_days 与有限值仍然不等（修复不得放宽语义）" {
  let nan = 0.0 / 0.0
  let a = ReviewEvent::new_with_raw(
    "c1",
    1700000000L,
    1699999000L,
    Good,
    3L,
    nan,
  )
  let b = ReviewEvent::new_with_raw(
    "c1",
    1700000000L,
    1699999000L,
    Good,
    3L,
    1.0,
  )
  assert_eq(ReviewEvent::equal(a, b), false)
  assert_eq(ReviewEvent::equal(b, a), false)
}
