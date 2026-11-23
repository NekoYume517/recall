// retention_curve 归桶对拍（2026-11-23 审计，攻击面 4）
//
// 背景：2026-11-21 把归桶从「bi = 0 起线性上扫」改成「除法起点 + 乘法双向校正」
// （O(1)）。两套实现的**语义**都应当是「最大 k 使 iv >= width·k，再封顶到末桶」。
// 既有 `stats_bucket_edge_regression_test.mbt` 钉住了 RC-8 的几个桶沿反例与
// 「末桶闭区间」，但没有对**任意样本**做逐点对拍。这里把旧实现（线性上扫）
// 作为独立参照复写一份，对多组 (max, buckets) × 多种样本形态逐点比对落桶：
//
//   - 桶沿本身（iv == width·k）
//   - 桶沿两侧的微小偏移（width·k·(1 ± 1e-15)）
//   - 任意位置（max·i/97）
//   - 最大值本身（必须落末桶）与 0
//   - 退化的全零样本 / 极小 max（桶宽下溢 → 单桶）
//
// 对拍口径：样本 iv 所在的返回行（lo <= iv < hi，末行闭区间）的桶号，必须与
// 参照实现给出的桶号逐点相同；并且每个样本恰好被一行包含。
//
// 造日志的方式（2026-11-23 修正）：**每张卡只放一条事件**，显式间隔即样本。
// 不能用同卡多事件 + 时间戳递增来「顺便」构造样本——`review_interval` 的
// 文档语义是「显式正间隔有效，否则按同卡前驱回推」，于是 elapsed=0 的
// 事件会回推出 60s ≈ 6.9e-4 天的**派生间隔**，把 max_elapsed 顶高、
// 把零样本变成非零样本，对拍的「样本集」前提整个失效（首轮跑挂即此因）。

///|
/// 旧实现（2026-11-21 之前）的归桶：从 bi = 0 起，只要 iv >= width·(bi+1) 就上扫。
fn curve_ref_bucket(iv : Double, width : Double, n : Int32) -> Int32 {
  let mut bi = 0
  while bi + 1 < n {
    if iv < width * (bi + 1).to_double() {
      break
    }
    bi = bi + 1
  }
  if bi >= n {
    n - 1
  } else {
    bi
  }
}

///|
/// 每张样本独立成卡、单条事件：显式间隔即样本，无派生间隔、无时间戳耦合。
fn curve_diff_log(samples : Array[Double]) -> ReviewLog {
  let log = ReviewLog::new()
  for i, iv in samples {
    log.push(
      ReviewEvent::new(
        "c\{i}",
        0L,
        0L,
        if i % 3 == 0 {
          Good
        } else {
          Again
        },
        iv,
      ),
    )
  }
  log
}

///|
/// 对一组样本做逐点对拍；返回不一致的样本数。
/// `edge_step` 控制桶沿取样密度（桶数很大时不必每个 k 都取）。
fn curve_diff_run(samples : Array[Double], n : Int32, label : String) -> Int32 {
  let mut max_elapsed = 0.0
  for iv in samples {
    if iv > max_elapsed {
      max_elapsed = iv
    }
  }
  let width = max_elapsed / n.to_double()
  if max_elapsed <= 0.0 || width == 0.0 {
    // 退化路径（全零 / 桶宽下溢）由单独用例锁定，这里不参与对拍
    return 0
  }
  let curve = retention_curve(curve_diff_log(samples), n)
  // 行 → 桶号：下界与实现同源（width * idx），行按桶号升序，单调前进反查
  let mut mismatch = 0
  let mut j = 0 // 下一个可能匹配的桶号
  let row_idx_of : Array[Int32] = []
  for row in curve {
    while j < n && width * j.to_double() != row.0 {
      j = j + 1
    }
    if j >= n {
      // 行下界不是任何 width·k：这本身就是归桶/标签不同源的证据
      println("label \{label}: n=\{n} 行下界 \{row.0} 不是 width·k")
      mismatch = mismatch + 1
    }
    row_idx_of.push(if j >= n { -1 } else { j })
    j = j + 1
  }
  let last_row = curve.length() - 1
  for iv in samples {
    let expected = curve_ref_bucket(iv, width, n)
    let mut containing = -1
    let mut rows_containing = 0
    for r, row in curve {
      let bi = row_idx_of[r]
      let inclusive = r == last_row
      if row.0 <= iv && (iv < row.1 || (inclusive && iv <= row.1)) {
        containing = bi
        rows_containing = rows_containing + 1
      }
    }
    if rows_containing != 1 {
      println("containment \{label}: n=\{n} iv=\{iv} rows=\{rows_containing}")
      mismatch = mismatch + 1
      continue
    }
    if containing != expected {
      mismatch = mismatch + 1
      println(
        "mismatch \{label}: n=\{n} iv=\{iv} expected=\{expected} got=\{containing}",
      )
    }
  }
  mismatch
}

///|
/// 构造一组样本：桶沿（按 step 取样）及其两侧偏移 + 任意位置 + 最大值。
/// 只收正样本：iv=0 在「每卡单事件」造法下不成为样本（无前驱可回推），
/// 留给退化用例按真实口径（同刻事件 → 派生 0）单独构造。
fn curve_diff_samples(
  max_elapsed : Double,
  n : Int32,
  step : Int32,
  extra : Int32,
) -> Array[Double] {
  let width = max_elapsed / n.to_double()
  let samples : Array[Double] = []
  let mut k = 1
  while k <= n {
    let edge = width * k.to_double()
    // 采样守卫：width·n 的舍入可能低于 max（如 179.9/10000），此时
    // edge·(1+1e-15) 会**超过** max——超出样本域的输入不是合法对拍样本
    // （实现没有义务覆盖 > max_elapsed 的间隔），跳过。
    if edge <= max_elapsed {
      samples.push(edge * (1.0 - 1.0e-15))
      samples.push(edge)
      let up = edge * (1.0 + 1.0e-15)
      if up < max_elapsed {
        samples.push(up)
      }
    }
    k = k + step
  }
  let mut i = 1
  while i < extra {
    samples.push(max_elapsed * i.to_double() / 97.0)
    i = i + 1
  }
  samples.push(max_elapsed)
  samples
}

///|
test "retention_curve 对拍: O(1) 归桶与线性上扫在桶沿/两侧/任意位置逐点一致" {
  let ns : Array[Int32] = [1, 2, 3, 7, 10, 11, 13, 37, 100, 101, 1000]
  let maxs : Array[Double] = [
    179.9, 180.0, 100.6, 1.0, 0.5, 0.1, 3.7, 12345.678, 1.0e6, 1.0e-9, 1.0e12,
  ]
  let mut total = 0
  for n in ns {
    for m in maxs {
      total = total +
        curve_diff_run(curve_diff_samples(m, n, 1, 40), n, "m=\{m}")
    }
  }
  assert_eq(total, 0)
}

///|
test "retention_curve 对拍: 桶数很大（9999 / 10000 = CLI 上限）时同样逐点一致" {
  let ns : Array[Int32] = [9999, 10000]
  let maxs : Array[Double] = [179.9, 100.6, 1.0, 0.5]
  let mut total = 0
  for n in ns {
    for m in maxs {
      // 桶沿每 97 个取一个（参照实现是 O(n) 线性上扫，控制总耗时）
      total = total +
        curve_diff_run(curve_diff_samples(m, n, 97, 7), n, "m=\{m}")
    }
  }
  assert_eq(total, 0)
}

///|
test "retention_curve 对拍: 样本恰在桶边界 width·k 时落在以该值为下界的桶（RC-8 不变）" {
  let n = 7
  let max_elapsed = 180.0
  let width = max_elapsed / n.to_double()
  let samples : Array[Double] = [
    width * 3.0,
    width * 6.0,
    width * 1.0,
    max_elapsed,
  ]
  let curve = retention_curve(curve_diff_log(samples), n)
  for iv in samples {
    if iv < max_elapsed {
      // 必须作为某桶的**下界**出现，且不作为任何桶的上界出现
      let mut as_lower = false
      for row in curve {
        if row.0 == iv {
          as_lower = true
        }
        if row.1 == iv {
          fail(
            "样本 \{iv} 不该是某桶的上界（旧除法法的矛盾形态）",
          )
        }
      }
      assert_true(as_lower)
    }
  }
  let last_row = curve[curve.length() - 1]
  assert_true(last_row.0 <= max_elapsed && max_elapsed <= last_row.1)
}

///|
test "retention_curve: width·n 舍入低于最大样本时，末桶上界仍须覆盖最大样本" {
  // IEEE 754 实测：179.9 / 10000 * 10000 = 179.89999999999998 < 179.9。
  // 修复前末桶上界取 width·n：最大样本 179.9 被封顶进末桶，却不被
  // 末桶标签 [width·9999, width·10000] 包含——「标签含自己桶内样本」
  // 的构造保证被打破（2026-11-23 逐点对拍暴露）。
  let log = ReviewLog::new()
  log.push(ReviewEvent::new("a", 0L, 0L, Good, 179.9))
  log.push(ReviewEvent::new("b", 0L, 0L, Again, 0.01))
  let curve = retention_curve(log, 10000)
  assert_true(curve.length() >= 1)
  let last = curve[curve.length() - 1]
  // 末桶闭区间必须覆盖最大样本
  assert_true(last.0 <= 179.9 && 179.9 <= last.1)
  // 其余样本仍被自己的行包含（上界与归桶同源的保证不变）
  let mut covered = false
  for row in curve {
    if row.0 <= 0.01 && 0.01 < row.1 {
      covered = true
    }
  }
  assert_true(covered)
}

///|
test "retention_curve 对拍: 退化路径——全零样本与桶宽下溢都返回单个真实范围桶" {
  // 全零样本的真实口径：同卡**同刻**事件，显式 0、按前驱回推也是 0。
  let zero_log = ReviewLog::new()
  zero_log.push(ReviewEvent::new("z", 0L, 0L, Good, 0.0))
  zero_log.push(ReviewEvent::new("z", 0L, 0L, Again, 0.0))
  zero_log.push(ReviewEvent::new("z", 0L, 0L, Good, 0.0))
  let zero = retention_curve(zero_log, 10)
  assert_eq(zero.length(), 1)
  assert_eq(zero[0].0, 0.0)
  assert_eq(zero[0].1, 0.0)
  // 桶宽下溢：max = 5e-324（最小次正规数），n = 2 ⇒ width = 0 ⇒ 单桶 [0, max]
  let tiny = retention_curve(curve_diff_log([5.0e-324]), 2)
  assert_eq(tiny.length(), 1)
  assert_eq(tiny[0].0, 0.0)
  assert_eq(tiny[0].1, 5.0e-324)
  // buckets <= 0 按单桶处理，不越界不崩溃
  let one = retention_curve(curve_diff_log([1.0, 2.0, 3.0]), 0)
  assert_eq(one.length(), 1)
  assert_eq(one[0].1, 3.0)
}

///|
test "retention_curve 对拍: 极端样本量级（1e308 与 5e-324 同在一份日志）不产生越界或 NaN" {
  let log = curve_diff_log([1.0e308, 5.0e-324, 1.0, 2.5])
  for n in [1, 3, 10, 1000] {
    let curve = retention_curve(log, n)
    assert_true(curve.length() >= 1)
    for row in curve {
      assert_false(row.0.is_nan())
      assert_false(row.1.is_nan())
      assert_false(row.2.is_nan())
      assert_true(row.0 <= row.1)
      assert_true(row.2 >= 0.0 && row.2 <= 1.0)
    }
  }
}
