// 回归测试：curve 全零间隔的空区间标签（对抗性审计 P3）。
//
// retention_curve 对 max_elapsed==0 的样本返回单桶 (0.0, 0.0, rate)，
// CLI 照搬分桶格式把标签打印成 "[0.0, 0.0)"——数学上的空区间，
// 读者会以为曲线丢了数据。应打闭区间或明确说明。

///|
test "zero_interval_label: 全零间隔打闭区间并说明" {
  // 与 stats.mbt retention_curve 的 max_elapsed==0 分支同型样本：
  // 同卡两次复习、间隔 0 天
  let lbl = zero_interval_label((0.0, 0.0, 1.0))
  // 不允许出现空区间记号 "[0.0, 0.0)"
  assert_false(lbl.contains(")"))
  assert_true(lbl.contains("[0.0, 0.0]"))
  assert_true(lbl.contains("全部为零间隔"))
}

///|
test "zero_interval_label: 正常桶不受影响" {
  let lbl = zero_interval_label((0.0, 5.0, 1.0))
  assert_eq(lbl, "[0.0, 5.0)")
  assert_eq(zero_interval_label((10.0, 20.0, 0.0)), "[10.0, 20.0)")
}
