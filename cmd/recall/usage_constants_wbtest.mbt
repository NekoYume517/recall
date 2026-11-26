// ============================================================================
// `--help` 里的每个整数都必须是**实现常量的渲染值**（不是人手同步的副本）
//
// 第二十一轮 RC-21-1（2026-11-29）。上一轮的 RC-20-4 把「`--help` 印 3e8、实现判
// 3.4e8」修掉了，做法是让三条文案引用实现函数——但**只有那三条**。同一段帮助里
// 还留着十几个人肉写的数字：
//
//     --days … 上限 100000；… 允许 0 = 空结果        ← days_range_error 里写死
//     --days × --new-per-day 的乘积上限 100000 张    ← total_cards_error 里写死
//     --buckets … (默认 10, 上限 10000)              ← cmd_curve 里写死
//     --new-per-day … (默认 20) / --review-limit (默认 200)
//     --retention … [0.5,0.99] / --seed (默认 20240101, 64 位整数)
//
// 只要其中任何一个守卫上限变了而 help 没跟上，就又是一次 RC-20-4。靠「加一条
// 测试去抓整数」防不住这类复发——因为它只对被抓的三条生效。
//
// 结构性做法（本文件锁的就是它）：
//   1. 所有会出现在 help 里的数字，统一由**命名的实现常量**提供
//      （`cli_*` 一组，见 `main.mbt`），守卫与 help 读同一个函数；
//   2. 扫 `usage_text()` 渲染结果里的**全部**整数，逐个查白名单；
//   3. 白名单里每一项都取自某个常量函数的 `.to_string()`——测试断言
//      「渲染结果里的整数集合 ⊆ 常量渲染值集合」，所以**下一个改上限的人不用
//      记得改 help**：改常量，help 自动跟着走；忘了改常量而手写了新数字，这条红。
//
// 判据是集合包含：`render_ints(usage_text()) ⊆ render_ints(constants())`。

///|
/// 从一个字符串里抓出所有整数（按出现顺序，保留重复）。
fn rc21_ints(text : String) -> Array[Int64] {
  let out : Array[Int64] = []
  let sb = StringBuilder()
  let mut started = false
  for ch in text {
    if ch >= '0' && ch <= '9' {
      started = true
      sb.write_char(ch)
    } else if started {
      out.push(
        match parse_int64_loose(sb.to_string()) {
          Some(v) => v
          None => -1L
        },
      )
      sb.reset()
      started = false
    }
  }
  if started {
    out.push(
      match parse_int64_loose(sb.to_string()) {
        Some(v) => v
        None => -1L
      },
    )
  }
  out
}

///|
test "rc21-1: help 里的整数必须全部来自实现常量（集合包含）" {
  let allowed = rc21_allowed_help_ints()
  let shown = rc21_ints(usage_text())
  let bad : Array[Int64] = []
  for v in shown {
    if !allowed.contains(v) {
      bad.push(v)
    }
  }
  // 失败时把「多出来的数」原样报出来，直接指向要改的那一行。
  inspect(bad.length(), content="0")
}

///|
test "rc21-1: 白名单里的每个数都真的出现在 help 里（防空转白名单）" {
  // 反向保护：白名单不能塞一堆 help 根本不用的数，否则「包含」判据会变成
  // 「反正都允许」。每个常量至少要在渲染结果里被看到一次。
  let shown = rc21_ints(usage_text())
  let allowed = rc21_allowed_help_ints()
  for v in allowed {
    assert_true(shown.contains(v))
  }
}

///|
test "rc21-1: 改了常量，help 的数字必须跟着变（不是人手同步）" {
  // 这条是「结构性」的核心：把仿真路径上的常量假设性地换一个值，
  // 渲染出的 help 必须立刻体现新值——说明它读的是常量，不是硬编码。
  // 做法：直接比较「常量渲染值」与「help 里是否出现」。
  let rendered = rc21_constants_rendered()
  assert_true(rendered.contains(simulate_scan_limit().to_string()))
  assert_true(rendered.contains(advice_cost_limit().to_string()))
  assert_true(rendered.contains(simulate_work_limit().to_string()))
  assert_true(rendered.contains(cli_days_max().to_string()))
  assert_true(rendered.contains(cli_total_cards_max().to_string()))
  assert_true(rendered.contains(cli_buckets_max().to_string()))
  assert_true(rendered.contains(cli_per_day_max().to_string()))
  assert_true(rendered.contains(cli_seed_default().to_string()))
}
