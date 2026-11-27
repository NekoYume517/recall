// ============================================================================
// RC-22-3：扫描量守卫的**显示公式**与判据不符（第二十二轮，2026-11-30）
//
// 现象：`simulate --days 8000 --new-per-day 12`（卡数 96000 ≤ 100000，两条
// 单轴守卫都过）被拒，stderr 写着
//
//   用法错误: simulate 的扫描量（--new-per-day × --days² ÷ 2，模拟器每天
//             两趟全表扫描）必须 <= 250000000，得到 12 × 8000² ÷ 2 = 383952000
//
// 而 `12 × 8000² ÷ 2` 逐字算是 **384000000**，与它自己给出的 383952000 差
// 48000。同一句话在 `--days 10001 --new-per-day 5` 上又是一次：
// 话里说 `5 × 10001² ÷ 2`（= 250050005），打印 250025000。
//
// 根因：判据用的是 `n·d·(d-1)/2`（模拟器第 0 天没有到期卡，所以是前缀和
// `0 + n + 2n + … + (d-1)n`，不是 `d²/2`），但提示语把它描述成 `d² ÷ 2`。
// 这不是舍入误差，是一条**写法两种语义**：5000/20 恰好能对上，8000/12 差 48000。
// 读者照提示里给的公式核对，永远算不出印出来的数。
//
// 本仓库的纪律 9（HANDOVER 31.9 之后）：「凡写进文档/提示的数字，必须能从
// 实现常量算出来」。这里连**公式本身**都要能对上，否则「可核对」是假的。
//
// 修复：提示语改成实际判据的算式 `--new-per-day × (--days − 1) × --days ÷ 2`。
//
// 判据（双向，且**不**用实现函数自证）：
//   1. 从文案里抽出「A × B² ÷ 2」的形态并按其字面求值，必须等于它印的数；
//      换句话说：文案里的公式必须与印出来的数自洽。修复前这条必然红。
//   2. 文案里必须出现 `(d − 1)` 因子——直接把「² ÷ 2」这种写法判负；
//   3. 边界不许松：5000/20 放行、5001/20 被拒、8000/12 仍被拒。
// ============================================================================

///|
/// 取错误消息里最后一个「= <数字>」的数字（测试内部粗解析）。
fn rc22_print_units(input : String) -> Int64 {
  let marker = "= "
  let mut msg = input
  let mut found = -1L
  let mut scanning = true
  while scanning {
    match msg.find(marker) {
      Some(i) => {
        let rest = msg[i + marker.length():]
        let sb = StringBuilder()
        for ch in rest {
          if ch >= '0' && ch <= '9' {
            sb.write_char(ch)
          } else {
            break
          }
        }
        if sb.to_string().length() == 0 {
          scanning = false
        } else {
          match parse_int64_loose(sb.to_string()) {
            Some(v) => found = v
            None => ()
          }
          msg = rest.to_owned()
        }
      }
      None => scanning = false
    }
  }
  found
}

///|
test "RC-22-3: 拒绝消息里的公式必须与它印出的数自洽" {
  let cases = [(8000, 12), (10001, 5), (100000, 1)]
  for (d, n) in cases {
    let msg = simulate_scan_error(d, n)
    assert_true(msg.length() > 0)
    println("msg=" + msg)
    let shown = rc22_print_units(msg)
    // 按**文案字面**重算：旧文案写 `n × d² ÷ 2`
    let literal_old = n.to_int64() * d.to_int64() * d.to_int64() / 2L
    // 按**真实判据**重算：`n × (d−1) × d ÷ 2`
    let literal_new = n.to_int64() * (d.to_int64() - 1L) * d.to_int64() / 2L
    // 判据 2：文案不能再写「² ÷ 2」那种丢了一天前驱的公式
    assert_false(msg.contains("d² ÷ 2"))
    assert_true(msg.contains("(--days − 1)"))
    // 判据 1：文案公式算出的数 == 印出来的数（这才是「可核对」的含义）
    assert_eq(literal_new, shown)
    // 而旧公式在两组参数上都对不上——这条是**缺陷的直接证据**，
    // 放在这里当守卫：将来若有人把判据改回 d²/2，literal_old == shown 就会成立，
    // 于是下面这条会红，逼他同时改文案或改判据。
    if d == 8000 || d == 10001 {
      assert_true(literal_old != shown)
    }
  }
}

///|
test "RC-22-3b: 改文案不许松守卫——边界仍逐位对齐" {
  inspect(simulate_scan_error(5000, 20), content="")
  assert_true(simulate_scan_error(5001, 20).length() > 0)
  assert_true(simulate_scan_error(8000, 12).length() > 0)
  assert_true(simulate_scan_units(8000, 12) > simulate_scan_limit())
}

///|
test "RC-22-3c: 判据是前缀和（第 0 天没有到期卡）" {
  for (d, n) in [(1, 100000), (5000, 20), (20000, 1), (8000, 12)] {
    let mut manual = 0L
    let mut k = 0
    while k < d {
      manual = manual + n.to_int64() * k.to_int64()
      k = k + 1
    }
    assert_eq(simulate_scan_units(d, n), manual)
  }
}
