# ⚠️ API 契约修正（重要，请立即阅读）

> 本文档覆盖 `API.md` 中**不可编译的写法**。以本文档为准。

## 修正 1：trait 不能直接作为类型

MoonBit **没有 trait object**。以下写法会报 `[4099] Scheduler is a trait, not a type`：

```moonbit
// ❌ 错误
pub fn run_scheduler(s : Scheduler, st : CardState, ...) -> String
pub fn by_name(n : String) -> Scheduler
pub fn replay(log : ReviewLog, scheduler : Scheduler) -> ReplayResult
pub fn check(history : History, model : Model, config : CheckConfig) -> CheckOutcome
```

**正确做法是下面两种之一。**

### 方案 A：泛型约束（编译期单态化，最快）

```moonbit
// ✅ 正确
pub fn[T : Scheduler] run_scheduler(s : T, st : CardState, g : Grade) -> String { ... }
```

注意泛型参数的写法：**`fn[T : Trait] name(...)`**，`[T]` 在函数名**前面**，不是后面。

```moonbit
// ❌ 语法错误
pub fn run_scheduler[S : Scheduler](s : S, ...)
// ✅ 正确
pub fn[S : Scheduler] run_scheduler(s : S, ...)
```

### 方案 B：枚举包装（运行期动态分发，需要按名字选算法时用）

```moonbit
// ✅ 正确
pub(all) enum AnyScheduler {
  Sm2(Sm2)
  Fsrs(Fsrs)
  Leitner(Leitner)
}

pub impl Scheduler for AnyScheduler with name(self) {
  match self {
    Sm2(s) => s.name()
    Fsrs(s) => s.name()
    Leitner(s) => s.name()
  }
}

pub impl Scheduler for AnyScheduler with review(self, st, g) {
  match self {
    Sm2(s) => s.review(st, g)
    Fsrs(s) => s.review(st, g)
    Leitner(s) => s.review(st, g)
  }
}

pub fn scheduler_by_name(n : String) -> AnyScheduler {
  match n {
    "sm2" => Sm2(Sm2::new())
    "fsrs" => Fsrs(Fsrs::new())
    _ => Leitner(Leitner::new())
  }
}
```

### 各项目的具体落法

**recall**

```moonbit
// 对外 API 用枚举（CLI 需要按名字选算法）
pub fn replay(log : ReviewLog, s : AnyScheduler) -> ReplayResult
pub fn simulate(s : AnyScheduler, config : SimConfig) -> SimResult
pub fn compare(log : ReviewLog, a : AnyScheduler, b : AnyScheduler) -> Comparison

// 内部实现用泛型，避免重复
pub fn[T : Scheduler] replay_with(log : ReviewLog, s : T) -> ReplayResult
```

`AnyScheduler` 就是 `Scheduler` 的「存在类型」包装。它本身也 `impl Scheduler`，所以泛型函数可以直接吃它。

**lincheck**

```moonbit
pub(all) enum AnyModel {
  Register(RegisterModel)
  Counter(CounterModel)
  Set(SetModel)
  Queue(QueueModel)
}

pub impl Model for AnyModel with name(self) { ... }
pub impl Model for AnyModel with init(self) { ... }
pub impl Model for AnyModel with apply(self, st, op) { ... }
pub impl Model for AnyModel with state_eq(self, a, b) { ... }
pub impl Model for AnyModel with state_hash(self, st) { ... }

// 对外
pub fn check(history : History, model : AnyModel, config : CheckConfig) -> CheckOutcome
pub fn check_default(history : History, model : AnyModel) -> CheckOutcome
// 内部
pub fn[M : Model] check_with(history : History, model : M, config : CheckConfig) -> CheckOutcome
```

## 修正 2：`derive(Eq, Debug)` 会产生 deprecation 警告

不影响编译，但会让输出很吵。两个选择：

- 接受警告（简单）
- 只 `derive(Debug)`，Eq 手动实现或干脆不 derive

建议：**错误类型和枚举只 `derive(Debug)`**，需要比较的地方手写 `fn T::equal(a, b) -> Bool`。

## 修正 3：`impl Trait for T with m1(...)` 的写法

两个方法要连写时：

```moonbit
// 分开写（推荐，清晰）
pub impl Scheduler for Sm2 with name(self) { "sm2" }
pub impl Scheduler for Sm2 with review(self, st, g) { ... }

// 或连写
pub impl Scheduler for Sm2 with name(self) { "sm2" } and review(self, st, g) { ... }
```

## 修正 4：`String` 插值里不能放带引号的表达式

```moonbit
// ❌ 有风险
println("x=\{m["key"]}")

// ✅ 安全
let v = m["key"]
println("x=\{v}")
```

## 修正 5：`println` 只能接一个参数，没有 `print`

```moonbit
// ❌
print("a")
// ✅
println("a")   // 带换行
// 想不换行：累积到 StringBuilder，最后一次性 println
```

## 已实测通过的最小范例

以下是**完整可编译**的代码，可以直接参考：

```moonbit
pub(all) enum Grade { Again; Good; Easy }

pub(all) struct CardState { stability : Double; reps : Int }

pub trait Scheduler {
  name(Self) -> String
  review(Self, CardState, Grade) -> CardState
}

pub(all) struct Sm2 { ef : Double }

pub impl Scheduler for Sm2 with name(self) { "sm2" }

pub impl Scheduler for Sm2 with review(self, st, g) {
  match g {
    Again => CardState::{ stability: 1.0, reps: 0 }
    Good => CardState::{ stability: st.stability * self.ef, reps: st.reps + 1 }
    Easy => CardState::{ stability: st.stability * self.ef * 1.3, reps: st.reps + 1 }
  }
}

pub fn[T : Scheduler] run_scheduler(s : T, st : CardState, g : Grade) -> String {
  let ns = s.review(st, g)
  "\{s.name()}:stab=\{ns.stability}"
}

pub(all) enum AnyScheduler {
  Sm2(Sm2)
}

pub impl Scheduler for AnyScheduler with name(self) {
  match self { Sm2(s) => s.name() }
}

pub impl Scheduler for AnyScheduler with review(self, st, g) {
  match self { Sm2(s) => s.review(st, g) }
}

pub fn scheduler_by_name(n : String) -> AnyScheduler {
  match n {
    "sm2" => Sm2(Sm2::{ ef: 2.5 })
    _ => Sm2(Sm2::{ ef: 2.5 })
  }
}
```

测试（`src/x_test.mbt`，白盒，不用 `@` 前缀）：

```moonbit
test "generic" {
  let st = CardState::{ stability: 1.0, reps: 0 }
  inspect(run_scheduler(Sm2::{ ef: 2.5 }, st, Good), content="sm2:stab=2.5")
}

test "enum dispatch" {
  let st = CardState::{ stability: 2.0, reps: 1 }
  let a = scheduler_by_name("sm2")
  assert_true(a.name() == "sm2")
  inspect(a.review(st, Good).stability, content="5")
}
```
