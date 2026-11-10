// RJ-A2（2026-11-10 审计）：grade ∈ (2^53, 2^54) 的奇数被 JSON 解析静默吸收。
//
// ## 缺陷形态（修复前）
//
// 2^53+1 = 9007199254740993 作为 JSON 数字解析成 Double 时，最近的
// 可表示值是 2^53 = 9007199254740992（ties-to-even），于是：
//
//   {"grade":9007199254740993} → Ok，grade_raw = 9007199254740992，
//   to_jsonl() 写回 ...992 —— **首次往返就被改写**。
//
// 而 2^53+2 = 9007199254740994 能被精确表示（偶数是 2 的倍数），
// 越界守卫 `> 2^53` 能拦住它；2^53+1 恰好在 Double 上等于 2^53，
// 守卫看不见原文，于是漏放。
//
// API.md:107-108 承诺「|grade| > 2^53 的输入在解析时报数据错误，而不是
// 静默改值」——对「会被向下舍入的奇数」失效。
//
// 修复：对 grade 字段做**字面原文**校验——纯整数写法（`-?\d+`）且绝对值
// 超过 2^53 时直接报 BadLine；带小数/指数的写法维持「四舍五入」的
// 文档化行为（那是刻意的归一化，不是静默改值）。

///|
fn rja2_parse_one(grade_text : String) -> Result[String, String] raise {
  let line = "{\"card_id\":\"g\",\"reviewed_at\":100,\"due_at\":0,\"grade\":" +
    grade_text +
    ",\"elapsed_days\":0}"
  let parsed = ReviewLog::from_jsonl(line)
  match parsed {
    Err(BadLine(_, msg)) => Err(msg)
    Err(_) => Err("other error")
    Ok(log) => Ok(log.to_jsonl())
  }
}

///|
test "RJ-A2: grade 2^53+1 必须报错而不是被静默舍成 2^53" {
  // 2^53+1 在 Double 里恰好是 2^53，旧守卫看不见；必须靠原文识别
  match rja2_parse_one("9007199254740993") {
    Ok(s) => fail("2^53+1 must be rejected, got: \{s}")
    Err(e) => assert_true(e.contains("grade"))
  }
}

///|
test "RJ-A2: grade 2^53+3 同样报错（向上舍入越界，旧守卫能拦）" {
  // 9007199254740995 是奇数，Double 上最近可表示值是 +4 后的偶数
  // （ties-to-even），落在 > 2^53 一侧，旧守卫本来就能拦住；
  // 这条锁定「修复没有放松既有拦截面」。
  match rja2_parse_one("9007199254740995") {
    Ok(s) => fail("2^53+3 must be rejected, got: \{s}")
    Err(e) => assert_true(e.contains("grade"))
  }
}

///|
test "RJ-A2: 恰好 2^53 仍接受且往返稳定（文档承诺的边界）" {
  match rja2_parse_one("9007199254740992") {
    Err(e) => fail("2^53 must be accepted: \{e}")
    Ok(s) => assert_true(s.contains("9007199254740992"))
  }
}

///|
test "RJ-A2: 2^53+2（偶数、可精确表示）仍按既有规则拒收" {
  match rja2_parse_one("9007199254740994") {
    Ok(s) => fail("2^53+2 must be rejected, got: \{s}")
    Err(e) => assert_true(e.contains("grade"))
  }
}

///|
test "RJ-A2: 普通小数 grade 仍按四舍五入归一（既有文档化行为不变）" {
  match rja2_parse_one("4.6") {
    Err(e) => fail("fractional grade must still round: \{e}")
    Ok(s) => assert_true(s.contains("\"grade\":5"))
  }
}
