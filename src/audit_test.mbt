// 对抗性审查的回归测试（recall-audit）

// 候选 1：Fsrs::with_params 负权重
///|
test "audit: with_params 负权重退回默认" {
  let f = Fsrs::with_params([-1.0, -1.0])
  assert_eq(f.w.length(), 21)
  assert_true(near(f.w[0], 0.40255))
}

// 候选 2：JSONL UTF-8 BOM

///|
test "audit: JSONL BOM 行可解析" {
  let text = "﻿{\"card_id\":\"c1\",\"reviewed_at\":100,\"due_at\":0,\"grade\":3,\"elapsed_days\":1}\n"
  match ReviewLog::from_jsonl(text) {
    Ok(log) => inspect(log.length(), content="1")
    Err(_) => inspect("BOM rejected", content="accepted")
  }
}

// 候选 3：Leitner retrievability 分段线性 vs 初始 1.0

///|
test "audit: Leitner retrievability 初始不高于复习后" {
  let sched = Leitner::new()
  let init_st = sched.init("c1", 0L)
  let r_new = sched.retrievability(init_st, 86400L * 3L)
  let after = sched.review(init_st, Grade::Good, 0L)
  let r_after = sched.retrievability(after, 0L + 86400L * 2L)
  // 初始卡（未复习）不应比刚复习过的卡"记得更牢"
  assert_true(r_after >= r_new)
}

// 候选 4：simultaneous grade 4 → statistics retention

///|
test "audit: Grade::from_int(-2147483648) 是 Again" {
  inspect(Grade::label(Grade::from_int(-2147483648)), content="again")
}

// 候选 5：by_card 稳定排序在负时间戳下

///|
test "audit: by_card 对同一秒多条保持文件顺序（跨卡片）" {
  let log = ReviewLog::new()
  log.push(ReviewEvent::new("x", -100L, 0L, Grade::Good, 0.0))
  log.push(ReviewEvent::new("x", -100L, 0L, Grade::Again, 0.0))
  log.push(ReviewEvent::new("x", -200L, 0L, Grade::Hard, 0.0))
  let groups = log.by_card()
  match groups.get("x") {
    Some(arr) => {
      inspect(arr[0].reviewed_at.to_string(), content="-200")
      inspect(arr[1].reviewed_at.to_string(), content="-100")
      inspect(Grade::label(arr[1].grade), content="good")
      inspect(Grade::label(arr[2].grade), content="again")
    }
    None => inspect("missing x", content="found")
  }
}

// ─────────────────────────────────────────────────────────────────
// 第二轮：JSONL 极端输入（全部通过 → 确认无 bug）
// ─────────────────────────────────────────────────────────────────

///|
test "audit: field_timestamp 拒绝超大时间戳（Int64 溢出防护）" {
  let text = "{\"card_id\":\"c1\",\"reviewed_at\":9000000000000,\"due_at\":0,\"grade\":3,\"elapsed_days\":1}\n"
  match ReviewLog::from_jsonl(text) {
    Ok(_) => inspect("overflow accepted", content="rejected")
    Err(BadTimestamp(_, _)) => inspect("rejected", content="rejected")
    Err(_) => inspect("wrong error", content="BadTimestamp")
  }
}

///|
test "audit: JSONL 负时间戳下界合法（公元 1 年）" {
  let text = "{\"card_id\":\"c1\",\"reviewed_at\":-62135596800,\"due_at\":-62135596800,\"grade\":3,\"elapsed_days\":0}\n"
  match ReviewLog::from_jsonl(text) {
    Ok(log) => inspect(log.events[0].reviewed_at.to_string(), content="-62135596800")
    Err(_) => inspect("rejected", content="accepted")
  }
}

///|
test "audit: grade 2.7 四舍五入为 Good(3)" {
  let text = "{\"card_id\":\"c1\",\"reviewed_at\":100,\"due_at\":0,\"grade\":2.7,\"elapsed_days\":1}\n"
  match ReviewLog::from_jsonl(text) {
    Ok(log) => inspect(Grade::label(log.events[0].grade), content="good")
    Err(_) => inspect("rejected", content="parsed")
  }
}

///|
test "audit: grade -0.4 → Again" {
  let text = "{\"card_id\":\"c1\",\"reviewed_at\":100,\"due_at\":0,\"grade\":-0.4,\"elapsed_days\":1}\n"
  match ReviewLog::from_jsonl(text) {
    Ok(log) => inspect(Grade::label(log.events[0].grade), content="again")
    Err(_) => inspect("rejected", content="parsed")
  }
}

///|
test "audit: JSONL NaN grade 被拒绝" {
  let text = "{\"card_id\":\"c1\",\"reviewed_at\":100,\"due_at\":0,\"grade\":NaN,\"elapsed_days\":1}\n"
  match ReviewLog::from_jsonl(text) {
    Ok(_) => inspect("nan accepted", content="rejected")
    Err(_) => inspect("rejected", content="rejected")
  }
}

///|
test "audit: 重复 card_id+时间戳的两条事件都保留且稳定有序" {
  let text = "{\"card_id\":\"c1\",\"reviewed_at\":100,\"due_at\":0,\"grade\":3,\"elapsed_days\":0}\n{\"card_id\":\"c1\",\"reviewed_at\":100,\"due_at\":0,\"grade\":1,\"elapsed_days\":0}\n"
  match ReviewLog::from_jsonl(text) {
    Ok(log) => {
      inspect(log.length(), content="2")
      let groups = log.by_card()
      match groups.get("c1") {
        Some(arr) => {
          inspect(Grade::label(arr[0].grade), content="good")
          inspect(Grade::label(arr[1].grade), content="hard")
        }
        None => inspect("missing c1", content="found")
      }
    }
    Err(_) => inspect("rejected", content="parsed")
  }
}
