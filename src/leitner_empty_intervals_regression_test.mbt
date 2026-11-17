///|
/// 审计回归（第十三轮，P1）：`Leitner` 的 `intervals` 为空表时**崩溃**。
///
/// ## 现象
///
/// `Leitner` 的两个字段都是 `pub(all)`，直接构造 `{ boxes: n, intervals: [] }`
/// 之后，任何一次 `init` / `review` 都会在 `Leitner::interval_of` 里
/// **数组下标越界 panic**（wasm 目标 `unreachable`，进程级崩溃）：
///
/// ```
/// let empty : Array[Double] = []
/// let l : Leitner = { boxes: 5, intervals: empty }
/// Scheduler::init(l, "c1", 0L)      // ← panic at Leitner::interval_of
/// ```
///
/// ## 根因
///
/// 第十二轮 `e0697f8` 把「盒数只有一个来源」收敛到 `effective_boxes()`，
/// 并且明文写进 `API.md` §3.3：
///
/// > 手工构造的不同步实例**不会崩**：`effective_boxes()` 取两者较小值兜底，
/// > 于是它退化成「一致的最小盒数」，而不是两个字段自相矛盾。
///
/// 但 `effective_boxes()` 对空表返回 **1**（盒号是 1-based，`leitner_box_of`
/// 也把 0 读成盒 1），而 `interval_of` 随后无条件读 `intervals[b - 1]` =
/// `intervals[0]` —— 空表没有第 0 项。于是「两个字段一致」成立、「不会崩」
/// 不成立：这条判断只在 `n >= 1` 时被论证过，`n == 0` 这一端漏了。
///
/// ## 判级理由
///
/// P1（崩溃）：不是错值、不是慢，是进程直接 trap。可达性 = `pub(all)` 直构
/// （DISCIPLINE §5.4：公开手工结构 ≠ parser 可达输入）；带校验的构造器
/// `Leitner::with_intervals(0, [])` 会返回 Err，但那只覆盖了愿意用它的调用方。

///|
fn leitner_empty_table(boxes : Int32) -> Leitner {
  let table : Array[Double] = []
  { boxes, intervals: table, }
}

///|
test "R13-1: intervals 为空时 init 不崩（退化成一盒、1 天兜底）" {
  let l = leitner_empty_table(5)
  let st = l.init("c", 0L)
  // 盒号 1、间隔 1 天、due 就是 now —— 与「表项为 NaN / 非正值」同一兜底。
  inspect(st.difficulty, content="1")
  inspect(st.interval_days, content="1")
  inspect(st.stability, content="1")
  inspect(st.due.to_string(), content="0")
  inspect(st.phase.label(), content="新卡")
}

///|
test "R13-1: intervals 为空时 review 不崩，且盒号与间隔自洽" {
  let l = leitner_empty_table(5)
  let mut st = l.init("c", 0L)
  st = l.review(st, Good, 86400L)
  inspect(st.difficulty, content="1")
  inspect(st.interval_days, content="1")
  inspect(st.reps, content="1")
  inspect(st.due.to_string(), content="172800")
  st = l.review(st, Again, 172800L)
  inspect(st.difficulty, content="1")
  inspect(st.interval_days, content="1")
  inspect(st.reps, content="1")
  inspect(st.lapses, content="1")
}

///|
test "R13-1: boxes 为 0 且 intervals 为空同样不崩" {
  let l = leitner_empty_table(0)
  let st = l.init("c", 0L)
  inspect(st.interval_days, content="1")
  let st2 = l.review(st, Easy, 86400L)
  inspect(st2.interval_days, content="1")
}

///|
test "R13-1: 负数 boxes 且 intervals 为空同样不崩" {
  let l = leitner_empty_table(-7)
  let st = l.init("c", 0L)
  inspect(st.interval_days, content="1")
}

///|
test "R13-1: 非空表（含不同步的手工表）行为逐位不变（防过度收紧）" {
  // 默认表：连续 Good 的盒号序列仍是 2,3,4,5,5,5，间隔 2,4,8,16,16,16。
  let d = Leitner::new()
  let mut st = d.init("c", 0L)
  let boxes_seen : Array[Double] = []
  let ivs : Array[Double] = []
  for i = 0; i < 6; i = i + 1 {
    st = d.review(st, Good, (i + 1).to_int64() * 86400L)
    boxes_seen.push(st.difficulty)
    ivs.push(st.interval_days)
  }
  inspect(boxes_seen[0], content="2")
  inspect(boxes_seen[3], content="5")
  inspect(boxes_seen[5], content="5")
  inspect(ivs[0], content="2")
  inspect(ivs[3], content="16")
  inspect(ivs[5], content="16")
  // 第十二轮锁过的「不同步但非空」场景仍退化成一盒。
  let mismatch : Leitner = { boxes: 10, intervals: [1.0], }
  let m = mismatch.init("c", 0L)
  inspect(m.interval_days, content="1")
  let m2 = mismatch.review(m, Good, 86400L)
  inspect(m2.difficulty, content="1")
  inspect(m2.interval_days, content="1")
}
