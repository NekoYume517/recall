///|
/// 审计回归（第十七轮 F3，2026-11-24）：**R(t=S) = 0.9 是定义性不变量，
/// 必须对全部 `s > 0` 逐位成立**。
///
/// 现象（修前实测）：`forgetting_curve(5e-324, 5e-324) = 1`。
/// 最小次正规数上不变量差了整整 10 个百分点；其余量级（1e-300 … 1.7e308）
/// 都是精确的 0.9，所以这个洞只在「s 小到 `factor·t` 先下溢」时才露出来。
///
/// 根因：`1 + factor * tt / s` 是「先乘后除」——`factor * tt` 在 tt 为次正规数
/// 时下溢成 0，`0 / s = 0`，于是 `pow(1, -0.5) = 1`。数值上真正想要的是
/// `tt / s`（比值），先除后乘既不下溢也不需要额外的量级守卫。
///
/// 修法：`factor * (tt / s)`。次正规数上 `t / s` 精确等于 1，`factor` 是最接近
/// 19/81 的 double，`pow(1 + factor, -0.5)` 逐位回到 0.9。
///
/// 可达性：`CardState` 是 `pub(all)`，`retrievability(state, now)` 直接吃外部
/// 状态的 `stability`；调度器自身路径把 s 夹到下限 0.1（`min_stability`），
/// 但这个不变量是**库级契约**，不是调度器内部实现细节。

///|
test "fsrs 曲线: R(t=S) 在最小次正规数上也逐位等于 0.9" {
  assert_eq(forgetting_curve(5.0e-324, 5.0e-324), 0.9)
}

///|
test "fsrs 曲线: R(t=S) 在 12 个量级上逐位等于 0.9" {
  let vals : Array[Double] = [
    5.0e-324, 1.0e-300, 1.0e-100, 1.0e-10, 1.0e-3, 0.1, 1.0, 2.5, 36500.0, 1.0e15,
    1.0e300, 1.7e308,
  ]
  for v in vals {
    assert_eq(forgetting_curve(v, v), 0.9)
  }
}

///|
test "fsrs 曲线: R(t=S) 在 1000 个步进值上逐位等于 0.9" {
  let mut i = 0
  while i < 1000 {
    let s = 0.1 + i.to_double() * 0.137
    assert_eq(forgetting_curve(s, s), 0.9)
    i = i + 1
  }
}

///|
test "fsrs 曲线: 修法不改变正常量级的值（防过度收紧）" {
  // 先乘后除与先除后乘在常态量级上只差 1 ulp 以内，这里钉住几个空开值
  // （参考值用 Python 独立复算：R(1,10)=0.9884739856290503、
  //  R(100,10)=0.5467110653077083、R(60,10)=0.6445033866354896）。
  assert_eq(forgetting_curve(0.0, 1.0), 1.0)
  assert_true(forgetting_curve(1.0, 10.0) > 0.988)
  assert_true(forgetting_curve(1.0, 10.0) < 0.989)
  assert_eq(forgetting_curve(10.0, 10.0), 0.9)
  assert_true(forgetting_curve(100.0, 10.0) > 0.546)
  assert_true(forgetting_curve(100.0, 10.0) < 0.547)
  // 单调不增：t 越大 R 越小
  let mut t = 0.0
  let mut prev = 2.0
  while t <= 60.0 {
    let cur = forgetting_curve(t, 7.0)
    assert_true(cur <= prev)
    prev = cur
    t = t + 0.5
  }
}
