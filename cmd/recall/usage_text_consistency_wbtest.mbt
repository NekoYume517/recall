// ============================================================================
// `--help` 里印出来的每个数字，必须等于实现里的那个数字
//
// 第二十轮 RC-20-4（2026-11-28）。上一轮把 `advice` 的成本上限从 `2.5e9` 收到
// `3e8`、又回调到 `3.4e8`，两次都只改了 `advice_cost_limit()` 的实现和注释，
// **`usage_text()` 里那行文案没跟上**：
//
//     $ recall --help
//       advice 的成本守卫: 探测上界 × --days² × --review-limit <= 300000000，超界 exit 2
//     $ recall advice --days 95 --review-limit 200      # 3.65e8
//       用法错误: … 必须 <= 340000000 …                  # 实际判据
//
// 用户照帮助里写的 `1e9` 去规划，会在 3.4e8 处被拒；照帮助里写的 `3e8` 去规划，
// 又会被执行 3.4e8 放行——帮助页与实际判据差 13%。这不是「注释过时」级别的瑕疵：
// 帮助页是这个 CLI 唯一的对外契约文本，`--review-limit` 那两行同理（它们各自
// 印着 `250000000` / `60000000`，也在下面一起锁）。
//
// 修法：把这几行文案改成**从实现取值**的字符串拼接（`advice_cost_limit()`、
// `simulate_scan_limit()`、`simulate_work_limit()`），并在这里逐一断言「帮助里
// 出现的就是实现里的数」。下次再调上限，帮助页自动跟着走。

///|
/// 从 `usage_text()` 里抓出某个锚点后面的第一个整数（没有则 -1）。
fn rc20_number_after(text : String, anchor : String) -> Int64 {
  let at = text.find(anchor)
  match at {
    None => -1L
    Some(idx) => {
      let rest = text.substring(start=idx + anchor.length(), end=text.length())
      let digits = StringBuilder()
      let mut started = false
      for ch in rest {
        if ch >= '0' && ch <= '9' {
          started = true
          digits.write_char(ch)
        } else if started {
          break
        }
      }
      match parse_int64_loose(digits.to_string()) {
        Some(v) => v
        None => -1L
      }
    }
  }
}

///|
test "rc20-4: 帮助里的 advice 成本上限等于实现值" {
  let help = usage_text()
  assert_eq(
    rc20_number_after(
      help, "advice 的成本守卫: 探测上界 × --days² × --review-limit <= ",
    ),
    advice_cost_limit(),
  )
}

///|
test "rc20-4: 帮助里的 simulate 扫描量上限等于实现值" {
  let help = usage_text()
  let printed = rc20_number_after(help, "的扫描量上限 ")
  assert_eq(printed, simulate_scan_limit())
}

///|
test "rc20-4: 帮助里的 simulate 运行时预算等于实现值" {
  let help = usage_text()
  let printed = rc20_number_after(help, "累计到期条数 <= ")
  assert_eq(printed, simulate_work_limit())
}
