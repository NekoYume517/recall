// 对抗性审查的回归测试（recall-audit）

// 候选 1：Fsrs::with_params 负权重
test "audit: with_params 负权重退回默认" {
  let f = Fsrs::with_params([-1.0, -1.0])
  assert_eq(f.w.length(), 21)
  assert_true(near(f.w[0], 0.40255))
}

// 候选 2：JSONL UTF-8 BOM
test "audit: JSONL BOM 行可解析" {
  let text = "﻿{\"card_id\":\"c1\",\"reviewed_at\":100,\"due_at\":0,\"grade\":3,\"elapsed_days\":1}\n"
  match ReviewLog::from_jsonl(text) {
    Ok(log) => inspect(log.length(), content="1")
    Err(_) => inspect("BOM rejected", content="accepted")
  }
}

// 候选 3：Leitner retrievability 分段线性 vs 初始 1.0
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
test "audit: Grade::from_int(-2147483648) 是 Again" {
  inspect(Grade::label(Grade::from_int(-2147483648)), content="again")
}

// 候选 5：by_card 稳定排序在负时间戳下
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
