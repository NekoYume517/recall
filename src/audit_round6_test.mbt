// RJ-A3 / RJ-A4 / RJ-A5（2026-11-10 审计）：
//   A3 curve 末桶标签与实际闭区间归桶自相矛盾
//   A4 两种「按 card_id 排序」并存（长度优先 vs 真字典序）
//   A5 advice 负目标给出自相矛盾的 summary
//
// 这三条都是「同一语义两套实现」或「文案与行为不符」，判定不受影响，
// 但用户看到的输出会误导排查方向。

// ---------------------------------------------------------------------------
// A4：排序必须是真的字典序（与 anki 导出、以及文档里的「字典序」一致）
// ---------------------------------------------------------------------------

///|
fn rja4_parse(text : String) -> ReviewLog raise {
  match ReviewLog::from_jsonl(text) {
    Ok(l) => l
    Err(_) => abort("bad fixture")
  }
}

///|
test "RJ-A4: per-card 统计按真字典序（f10 在 f2 之前）" {
  // 长度优先序会把 "f2" 排在 "f10" 前面（"f2" 更短），字典序相反。
  let text = "{\"card_id\":\"f2\",\"reviewed_at\":10,\"due_at\":20,\"grade\":2,\"elapsed_days\":0}\n" +
    "{\"card_id\":\"f10\",\"reviewed_at\":10,\"due_at\":20,\"grade\":2,\"elapsed_days\":0}\n" +
    "{\"card_id\":\"f1\",\"reviewed_at\":10,\"due_at\":20,\"grade\":2,\"elapsed_days\":0}\n"
  let rows = compute_stats(rja4_parse(text))
  let ids : Array[String] = []
  for st in rows {
    ids.push(st.card_id)
  }
  assert_eq(ids[0], "f1")
  assert_eq(ids[1], "f10")
  assert_eq(ids[2], "f2")
}

///|
test "RJ-A4: replay 快照顺序与 stats 一致（同为字典序）" {
  let text = "{\"card_id\":\"f2\",\"reviewed_at\":10,\"due_at\":20,\"grade\":2,\"elapsed_days\":0}\n" +
    "{\"card_id\":\"f10\",\"reviewed_at\":10,\"due_at\":20,\"grade\":2,\"elapsed_days\":0}\n"
  let res = replay(rja4_parse(text), AnyScheduler::Sm2(Sm2::new()))
  let ids : Array[String] = []
  for snap in res.snapshots {
    let (_, cid, _) = snap
    if !ids.contains(cid) {
      ids.push(cid)
    }
  }
  assert_eq(ids[0], "f10")
  assert_eq(ids[1], "f2")
}

// ---------------------------------------------------------------------------
// A5：负目标必须如实拒绝，不能编「存量太大」
// ---------------------------------------------------------------------------

///|
test "RJ-A5: advice 负目标给出无效输入说明，不再说存量太大" {
  let req = AdviceRequest::{
    days: 10,
    review_limit: 20,
    desired_retention: 0.9,
    policy_factory: fn() { fn(_) { Grade::Good } },
    seed: 1L,
    target_backlog: -1,
  }
  let res = load_advice(AnyScheduler::Fsrs(Fsrs::new()), req)
  assert_true(res.summary.contains("无效"))
  assert_true(!res.summary.contains("存量太大"))
  assert_eq(res.new_per_day, 0)
}
