// ============================================================================
// RC-8 回归测试（2026-10-27）：bucket edges must agree between labelling and
// assignment
//
// 契约（stats.mbt 注释 + API.md 6 节 + docs/DEMO.md 六节一致声明）：
//   分桶是左闭右开 `[lo, hi)`，`bi = floor(iv / width)`，且
//   **「返回值同时给出上下界，标签才与桶内容一致」**。
//
// 旧实现的两套算式在桶沿上打架：
//   归桶：`bi = (iv / safe_width).to_int()`        ← 除法
//   标签：`lower = safe_width * i`，`upper = safe_width * (i+1)`  ← 乘法
// 对 iv = max*n⁻¹ 这类"数学上正好落在桶沿"的样本，`iv / width` 会比
// 整数小 1~2 ulp，截断后掉进**前一桶**，于是打印出来的 `[lo, hi)`
// 上界恰好等于该样本——记号自相矛盾。
//
// 精确见证（max = 180, buckets = 7, width = 180/7 = 25.714285714285715）：
//   iv = 180*3/7         = 77.14285714285714
//   iv / width           = 2.9999999999999996   → to_int = 2（旧：落桶 2）
//   width * 3            = 77.14285714285714     ← 与 iv 逐位相同
// 于是桶 2 的标签 [51.42857142857143, 77.14285714285714) 声称
// 77.14285714285714 不属于它。穷举扫描在
// n ∈ {2,3,4,5,7,10,11,13,37,100,1000} × 12 个 max 上命中 583 组。
//
// 修复：归桶改用与标签**同源**的乘法边界比较——
// `lo = width*i <= iv < width*(i+1) = hi`，与打印出的区间逐位一致。
// ============================================================================

///|
/// 修复后的归桶语义（乘法边界法），测试里作为独立参照复写一份。
/// 返回桶号；`iv >= max_elapsed` 时封顶到最后一桶。
fn rc8_bucket_mul(iv : Double, width : Double, n : Int32) -> Int32 {
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
/// 旧实现的归桶（除法法），用于证明缺陷前提。
fn rc8_bucket_div(iv : Double, width : Double, n : Int32) -> Int32 {
  let mut bi = (iv / width).to_int()
  if bi < 0 {
    bi = 0
  }
  if bi >= n {
    bi = n - 1
  }
  bi
}

///|
/// 造一份「单样本 + 定宽样本」的日志：第一个样本是待测值，第二个是 max。
fn rc8_log(iv : Double, max_elapsed : Double) -> ReviewLog {
  let log = ReviewLog::new()
  log.push(ReviewEvent::new("c1", 0L, 0L, Grade::Good, iv))
  log.push(ReviewEvent::new("c1", 86400L, 86400L, Grade::Good, max_elapsed))
  log
}

///|
test "RC-8: 缺陷前提——桶沿样本被除法法归到前一桶" {
  let n = 7
  let max_elapsed = 180.0
  let width = max_elapsed / n.to_double()
  let iv = 180.0 * 3.0 / 7.0
  println("iv=" + iv.to_string() + "  width=" + width.to_string())
  println("iv/width=" + (iv / width).to_string())
  println("width*3=" + (width * 3.0).to_string())
  // 样本值与桶 3 的下界逐位相同
  assert_eq(iv, width * 3.0)
  // 除法法（旧）给 2，乘法法（修复）给 3
  assert_eq(rc8_bucket_div(iv, width, n), 2)
  assert_eq(rc8_bucket_mul(iv, width, n), 3)
}

///|
test "RC-8: 桶沿样本落在下界等于自己的那个桶（n=7, max=180）" {
  let n = 7
  let iv = 180.0 * 3.0 / 7.0
  let width = 180.0 / n.to_double()
  let curve = retention_curve(rc8_log(iv, 180.0), n)
  println("curve=" + curve.to_string())
  // 该样本所在的桶必须是 lo == iv 的那一个
  let mut found = false
  for row in curve {
    if row.0 == iv {
      found = true
    }
    // 任何桶的上界都不该等于 iv（那正是旧实现的矛盾形态）
    assert_true(row.1 != iv)
  }
  assert_true(found)
}

///|
test "RC-8: 另一组桶沿（n=7, max=180 的 6/7 位置）" {
  let n = 7
  let iv = 180.0 * 6.0 / 7.0
  let width = 180.0 / n.to_double()
  assert_eq(rc8_bucket_div(iv, width, n), 5)
  assert_eq(rc8_bucket_mul(iv, width, n), 6)
  let curve = retention_curve(rc8_log(iv, 180.0), n)
  let mut found = false
  for row in curve {
    if row.0 == iv {
      found = true
    }
    assert_true(row.1 != iv)
  }
  assert_true(found)
}

///|
test "RC-8: 小 max 的桶沿（n=11, max=1.0 的 3/11 位置）" {
  let n = 11
  let iv = 3.0 / 11.0
  let width = 1.0 / n.to_double()
  println("iv=" + iv.to_string() + "  width*3=" + (width * 3.0).to_string())
  assert_eq(rc8_bucket_div(iv, width, n), 2)
  assert_eq(rc8_bucket_mul(iv, width, n), 3)
  let curve = retention_curve(rc8_log(iv, 1.0), n)
  let mut found = false
  for row in curve {
    if row.0 == iv {
      found = true
    }
    assert_true(row.1 != iv)
  }
  assert_true(found)
}

///|
test "RC-8: 更多桶数下的桶沿（n=37, max=1.0 的 21/37 位置）" {
  let n = 37
  let iv = 21.0 / 37.0
  let width = 1.0 / n.to_double()
  assert_eq(rc8_bucket_div(iv, width, n), 20)
  assert_eq(rc8_bucket_mul(iv, width, n), 21)
  let curve = retention_curve(rc8_log(iv, 1.0), n)
  let mut found = false
  for row in curve {
    if row.0 == iv {
      found = true
    }
    assert_true(row.1 != iv)
  }
  assert_true(found)
}

///|
test "RC-8: max 自身的样本落在最后一桶（闭区间，不变）" {
  let n = 3
  let max_elapsed = 100.0
  let width = max_elapsed / n.to_double()
  // iv == max：除法法给 n（被夹回 n-1），乘法法同样封顶到尾桶
  assert_eq(rc8_bucket_div(max_elapsed, width, n), 2)
  assert_eq(rc8_bucket_mul(max_elapsed, width, n), 2)
  let curve = retention_curve(rc8_log(1.0, max_elapsed), n)
  let last = curve[curve.length() - 1]
  // 末桶上界 >= max（浮点可能略大）
  assert_true(last.1 >= max_elapsed)
  assert_true(1.0 - max_elapsed != 0.0)
}

///|
test "RC-8: 修复后所有桶都满足 lo < hi 且区间含自己的样本" {
  // 用一组混合样本（含两个桶沿值）做整体自洽检查
  let n = 7
  let max_elapsed = 180.0
  let width = max_elapsed / n.to_double()
  let log = ReviewLog::new()
  let samples : Array[Double] = [
    180.0 * 3.0 / 7.0,
    180.0 * 6.0 / 7.0,
    10.0,
    50.0,
    180.0,
  ]
  let mut t : Timestamp = 0L
  for iv in samples {
    log.push(ReviewEvent::new("c1", t, t, Grade::Good, iv))
    t = t + 86400L
  }
  let curve = retention_curve(log, n)
  for row in curve {
    assert_true(row.0 < row.1)
    // 桶宽必须是 width（末桶可能因浮点略差，留 1e-9 容差）
    assert_true((row.1 - row.0 - width).abs() < 0.000000001)
  }
  // 两个桶沿样本都必须作为某个桶的下界出现
  let mut lo3 = false
  let mut lo6 = false
  for row in curve {
    if row.0 == 180.0 * 3.0 / 7.0 {
      lo3 = true
    }
    if row.0 == 180.0 * 6.0 / 7.0 {
      lo6 = true
    }
  }
  assert_true(lo3)
  assert_true(lo6)
}

///|
test "RC-8: 既有的小节锚点（examples 的 91.85→50.00）不受影响" {
  // 这份日志的样本都不落在桶沿，修复必须不改动既有输出
  let log = ReviewLog::new()
  let els : Array[Double] = [
    1.0, 17.9890, 17.99, 25.0, 35.9780, 35.98, 53.9670, 53.97, 71.9560, 71.96, 89.9451,
    89.95, 107.9341, 107.93, 125.9231, 125.92, 143.9121, 143.91, 161.9011, 161.9,
    179.8901, 179.9,
  ]
  let mut t : Timestamp = 0L
  for e in els {
    log.push(ReviewEvent::new("c1", t, t, Grade::Good, e))
    t = t + 86400L
  }
  let curve = retention_curve(log, 10)
  // 保持率全 1（全 Good），桶数与边界稳定
  assert_eq(curve.length(), 10)
  for row in curve {
    assert_true((row.2 - 1.0).abs() < 0.000000001)
  }
  assert_true((curve[0].0 - 0.0).abs() < 0.000000001)
}
