// recall — CardState::equal 的自反性
//
// 现象：`CardState::equal(st, st)` 在 `stability` / `difficulty` /
// `interval_days` 任一为 NaN 时返回 **false**，即一个状态与它自己不相等。
//
// 根因：`types.mbt` 的 `CardState::equal` 用 `==` 逐字段比较浮点字段，
// 浮点的 `NaN == NaN` 恒假，相等关系因此破坏自反性。
//
// 为什么这条路径可达（不是理论分支）：`CardState` 是 `pub(all)`，三个浮点
// 字段可以直接构造；API.md 第 6 节明确说「`state.interval_days` 为
// `±Infinity` / `NaN`（只可能来自手工构造的状态）」——手工构造的 NaN 状态
// 是被文档承认的输入形态，测试里也用它验 `retrievability` 的兜底。
//
// 为什么要锁：`CardState::equal` 的注释写明「逐字段手写比较」，它是项目里
// 「状态是否同一」的唯一判定器（`replay` 的逐帧对比、`compare` 的差异检查
// 都依赖它）。不自反的相等关系会让这些对比**假阴性**：状态没变却判为变了。
//
// 与 `ReviewEvent::equal` 的 NaN 修复同族（同一轮审计，同一失效模式）。

///|
test "types: CardState::equal 对 NaN stability 自反" {
  let nan = 0.0 / 0.0
  let st : CardState = { ..CardState::new("c1", 0L), stability: nan, }
  assert_eq(CardState::equal(st, st), true)
}

///|
test "types: CardState::equal 对 NaN difficulty 自反" {
  let nan = 0.0 / 0.0
  let st : CardState = { ..CardState::new("c1", 0L), difficulty: nan, }
  assert_eq(CardState::equal(st, st), true)
}

///|
test "types: CardState::equal 对 NaN interval_days 自反" {
  let nan = 0.0 / 0.0
  let st : CardState = { ..CardState::new("c1", 0L), interval_days: nan, }
  assert_eq(CardState::equal(st, st), true)
}

///|
test "types: 三个字段同为 NaN 的两个状态相等（对称）" {
  let nan = 0.0 / 0.0
  let a : CardState = {
    ..CardState::new("c1", 0L),
    stability: nan,
    difficulty: nan,
    interval_days: nan,
  }
  let b : CardState = {
    ..CardState::new("c1", 0L),
    stability: nan,
    difficulty: nan,
    interval_days: nan,
  }
  assert_eq(CardState::equal(a, b), true)
  assert_eq(CardState::equal(b, a), true)
}

///|
test "types: NaN 与有限值仍然不等（修复不得放宽语义）" {
  let nan = 0.0 / 0.0
  let a : CardState = { ..CardState::new("c1", 0L), stability: nan, }
  let b : CardState = { ..CardState::new("c1", 0L), stability: 1.0, }
  assert_eq(CardState::equal(a, b), false)
  assert_eq(CardState::equal(b, a), false)
}

///|
test "types: CardState::equal 的分派字段仍然逐字段区分" {
  let base = CardState::new("c1", 0L)
  let other = { ..base, reps: base.reps + 1, }
  assert_eq(CardState::equal(base, other), false)
  assert_eq(CardState::equal(base, base), true)
}
