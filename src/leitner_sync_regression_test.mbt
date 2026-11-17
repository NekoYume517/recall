///|
/// 审计回归（第十二轮，P3）：`Leitner` 的 `boxes` 与 `intervals` 手工不同步。
///
/// ## 现象
///
/// 两个字段都是 `pub(all)`，手工构造时可能不同步：
///
/// ```
/// let l : Leitner = { boxes: 10, intervals: [1.0] }
/// ```
///
/// 修复前 `review` 用 `self.boxes` 夹盒号、`interval_of` 用
/// `intervals.length()` 夹，于是连续 Good 之后这张卡是
/// **`difficulty = 10`（盒 10）而 `interval_days = 1.0`（盒 1 的间隔）**——
/// 同一张卡两个字段自相矛盾，而且它会永远每天复习一次；
/// `compare` 的 total_interval、`stats` 的 mean/max_interval 全跟着失真。
///
/// 这是 DISCIPLINE §5.4 那一类（公开手工结构 ≠ parser 可达输入）。

///|
fn leitner_mismatch() -> Leitner {
  // boxes 说 10 盒，intervals 只给了 1 项。
  { boxes: 10, intervals: [1.0], }
}

///|
test "leitner 同步：手工不同步时盒号不超过间隔表（单一口径 effective_boxes）" {
  let l = leitner_mismatch()
  let mut st = l.init("c", 0L)
  for i = 0; i < 5; i = i + 1 {
    st = l.review(st, Good, (i + 1).to_int64() * 86400L)
  }
  // 盒号必须落在间隔表内（=1），而不是报告「盒 10」。
  inspect(st.difficulty, content="1")
  // 间隔与盒号必须自洽：interval_days == intervals[box-1]。
  inspect(st.interval_days, content="1")
  // 复习次数照常累加（不是被守卫短路的死卡）。
  inspect(st.reps, content="5")
}

///|
test "leitner 同步：不同步实例不再「永远每天到期」" {
  let l = leitner_mismatch()
  let mut st = l.init("c", 0L)
  st = l.review(st, Easy, 0L)
  // intervals=[1.0] ⇒ 无论进哪个盒，间隔都是 1 天；关键是 due 与 interval 一致。
  let due_gap = (st.due - st.last_review) / 86400L
  inspect(due_gap, content="1")
}

///|
test "leitner 同步：带校验的构造器显式拒绝不同步，并复制输入" {
  // 长度不匹配 → Err，消息里两个数都给出。
  match Leitner::with_intervals(3, [1.0, 2.0]) {
    Ok(_) => fail("长度不匹配必须被拒")
    Err(msg) => {
      assert_true(msg.contains("必须等于 boxes"))
      assert_true(msg.contains("3"))
      assert_true(msg.contains("2"))
    }
  }
  // boxes < 1 → Err。
  match Leitner::with_intervals(0, []) {
    Ok(_) => fail("boxes < 1 必须被拒")
    Err(msg) => assert_true(msg.contains("boxes 必须 >= 1"))
  }
  // 匹配 → Ok，且数组被复制（外部改动不影响实例）。
  let src = [1.0, 2.0, 4.0]
  match Leitner::with_intervals(3, src) {
    Ok(l) => {
      inspect(l.boxes, content="3")
      src[0] = 999.0
      inspect(l.intervals[0], content="1")
    }
    Err(_) => fail("匹配的盒表不该被拒")
  }
}

///|
test "leitner 同步：默认与 with_boxes 的行为逐位不变（防过度收紧）" {
  let d = Leitner::new()
  inspect(d.boxes, content="5")
  inspect(d.intervals.length(), content="5")
  // 默认表仍是 1/2/4/8/16，连续 Good 的盒号序列仍是 2..5。
  let mut st = d.init("c", 0L)
  let seen : Array[Double] = []
  for i = 0; i < 6; i = i + 1 {
    st = d.review(st, Good, (i + 1).to_int64() * 86400L)
    seen.push(st.difficulty)
  }
  inspect(seen.length(), content="6")
  // 盒号 2,3,4,5,5,5
  inspect(seen[0], content="2")
  inspect(seen[1], content="3")
  inspect(seen[3], content="5")
  inspect(seen[5], content="5")
  // with_boxes 仍然生成 2 的幂表，且两个字段等长。
  let b = Leitner::with_boxes(17)
  inspect(b.boxes, content="17")
  inspect(b.intervals.length(), content="17")
}
