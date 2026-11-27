// 回归测试：curve 的 `[0, 0]` 桶标签（第二十二轮 RC-22-2）。
//
// RC-22-1 让零间隔样本单独成桶 `[0, 0]`。此前 `[0, 0]` 只会在
// 「**全部**样本都是零间隔」时出现（`max_elapsed == 0` 分支），所以
// `keyboard` 里的标签写死成「全部为零间隔」没问题。
//
// 但混入正间隔样本之后，同一个 `[0, 0]` 行依旧被打成
// 「全部为零间隔」——日志里明明有 20 天的样本，曲线也画出了 `[15, 20]`
// 那一行，读者看到「全部为零间隔」只能认为标签在说谎。
//
// 判据（双向）：
//   - 只有零间隔样本 ⇒ 保留「全部为零间隔」；
//   - 混有正间隔样本 ⇒ 必须改说「零间隔样本」而不带「全部」。

///|
test "RC-22-2: 混有正间隔样本时 [0,0] 标签不得声称「全部为零间隔」" {
  let lbl = zero_interval_label((0.0, 0.0, 1.0), false)
  println("label=" + lbl)
  assert_false(lbl.contains("全部"))
  assert_true(lbl.contains("零间隔"))
  assert_true(lbl.contains("[0.0, 0.0]"))
}

///|
test "RC-22-2b: 只有零间隔样本时保留「全部为零间隔」口径" {
  let lbl = zero_interval_label((0.0, 0.0, 1.0), true)
  println("label=" + lbl)
  assert_true(lbl.contains("[0.0, 0.0]"))
  assert_true(lbl.contains("全部为零间隔"))
  assert_false(lbl.contains(")"))
}

///|
test "RC-22-2c: 正常桶标签不受影响" {
  assert_eq(zero_interval_label((0.0, 5.0, 1.0), false), "[0.0, 5.0)")
  assert_eq(zero_interval_label((10.0, 20.0, 0.0), true), "[10.0, 20.0)")
}
