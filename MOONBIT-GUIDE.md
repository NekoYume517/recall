# MoonBit 语法与工具链速查（本仓库实测可用）

> 本文档由实测得出，所有片段均在本机 `moon 0.1.20261012 / moonc v0.10.15` 通过编译。
> **写代码前先读一遍**，能省掉大量编译错误往返。

## 1. 工具链

```powershell
$env:MOON_HOME="E:\moonbit\home"; $env:Path="E:\moonbit\home\bin;"+$env:Path
moon check      # 类型检查，最快
moon test       # 跑测试
moon run cmd/xxx
moon build --target wasm
moon info       # 生成 pkg.generated.mbti
moon fmt        # 格式化（提交前必跑）
```

## 2. 包组织

```
moon.mod          # 模块清单
src/
  moon.pkg        # pkgtype(kind: "library")
  *.mbt           # 库代码
  *_test.mbt      # 白盒测试：同包，直接写符号名
  *_wbtest.mbt    # 黑盒测试：需 @别名 前缀 + for "wbtest" 导入
cmd/<name>/
  moon.pkg        # pkgtype(kind: "executable")
  main.mbt        # fn main
```

**测试两种写法（关键，很容易搞错）：**

```moonbit
// src/foo_test.mbt  —— 白盒，不需要 @ 前缀
test "white" {
  let f = Field::new("A", 0)      // 直接调用
  inspect(f.name, content="A")
}
```

```moonbit
// src/foo_wbtest.mbt —— 黑盒，需要在 moon.pkg 里显式自导入
// moon.pkg:
//   import { "NekoYume517/xxx/src" @xxx } for "wbtest"
test "black" {
  let f = @xxx.Field::new("A", 0)  // 必须带 @xxx
  inspect(f.name, content="A")
}
```

`moon.pkg` 导入写法：

```moonbit
import {
  "moonbitlang/core/json" @json,
  "NekoYume517/copybook/src" @copybook,
}

pkgtype(kind: "library")   // 或 "executable"
```

- **`pkgtype` 只有 `library` / `executable` / `foreign_library`**，没有 `lib`。
- 模块内包引用**必须写完整路径** `模块名/src`，不能只写模块名。
- 测试文件里的符号要用 `@包名.foo` 限定（否则警告 `test_unqualified_package`）。

## 3. 基础语法

### 函数

```moonbit
fn add(a : Int, b : Int) -> Int { a + b }

// 公开 API 加 pub
pub fn parse(s : StringView) -> Result[Int, ParseError] { ... }

// 可失败函数用 raise
pub fn parse_double(s : StringView) -> Double raise { ... }
```

### 方法（第一个参数是 self）

```moonbit
pub fn Doc::size(self : Doc) -> Int { self.items.length() }
// 调用：doc.size()
```

### 枚举 + 模式匹配

```moonbit
pub(all) enum Token {
  Num(Int)
  Str(String)
  Eof
}

fn describe(t : Token) -> String {
  match t {
    Num(n) => "num:\{n}"
    Str(s) => "str:\{s}"
    Eof => "eof"
  }
}
```

`pub(all)` 才能让外部构造/匹配。

### 结构体

```moonbit
pub(all) struct Field {
  name : String
  offset : Int
  mut length : Int      // mut 字段需要 struct 值本身可写
}

let f = Field::{ name: "A", offset: 0, length: 8 }
```

**注意**：非 `pub(all)` 的结构体在下游（含测试）**不能**用 `Type::{ ... }` 构造，会报 `Cannot create values of the read-only type`。

### 错误类型

```moonbit
pub(all) suberror ParseError {
  UnexpectedChar(pos : Int, ch : Char)
  UnexpectedEof
} derive(Eq, Debug)
```

`suberror` 才能和 `raise` 组合。`derive(Eq)` 会有 deprecation 警告，可以用，也可以忽略。

### Trait

```moonbit
pub trait Scheduler {
  next_interval(Self, ReviewState) -> Int
  name(Self) -> String
}

pub impl Scheduler for Sm2 with next_interval(self, st) { ... }
// 或
pub impl Scheduler for Sm2 with name(self) { "sm2" } and next_interval(self, st) { ... }
```

## 4. 字符串 / 字节

```moonbit
// String 是 UTF-16
let s = "abc"
s.length()                    // 码元数
s[i]                          // UInt16（可比较字符字面量）
s.get_char(i)                 // Char?
s.to_array()                  // Array[Char]
s.substring(start=0, end=2)
s.split(",")                  // Iter[StringView]
s.split(",").collect()        // Array[StringView]
s.contains("b")
s.has_prefix("a")
s.to_lower() / s.to_upper()
s.find("b")                   // Int?

// StringView -> String
let owned : String = sv.to_owned()      // 用 to_owned，不要用 to_string（已弃用）

// Bytes
let b : Bytes = b"\x00\x61"
b.length()
b[i]                          // Byte
b.to_array()                  // Array[Byte]
Bytes::from_array(arr)        // Array[Byte] -> Bytes
b[i].to_int()
```

**没有 `print`**（只有 `println`）。要拼输出用 `StringBuilder`：

```moonbit
let sb = StringBuilder()
sb.write_string("x")
sb.write_char('y')
println(sb.to_string())
```

**注意**：`let sb = StringBuilder()` 后再 `sb.write_*` 不需要 `mut`，加了会报 `unused_mut`。

## 5. 集合

```moonbit
let a : Array[Int] = []
a.push(1)                     // 不需要 mut 绑定
a.length()
a.sort()                      // 原地
a.sort_by(fn(x, y) { y - x })
let m : Map[String, Int] = Map([])   // 不能用 {}（歧义）
m["k"] = 1
m.get("k")                    // Int?
m.keys() / m.values()
for k, v in m { ... }
```

**遍历 Array 带下标**：`for i, v in arr { ... }`

## 6. 数值

```moonbit
1.to_double()
2.5.to_int()                  // 截断
"42".parse_int()              // 需 import strconv，Result 风格
@strconv.parse_int("42")      // Int raise
@strconv.parse_double("1.5")  // Double raise
n.to_string(radix=16)
@math.log2(x) / @math.pow(a, b) / @math.floor(x)
```

## 7. 测试

```moonbit
test "name" {
  inspect(1 + 1, content="2")
  assert_eq(a, b)
  assert_true(cond)
}

test "raises" {
  inspect(parse("x") is Err(_), content="true")
}
```

`inspect(x, content="...")` 比对 `Show` 输出，注意 `1.0` 会显示成 `1`。

## 8. 数学库（实测）

```moonbit
@math.pow(a, b)
@math.exp(x)
@math.ln(x)        // ⚠️ 是 ln，不是 log
@math.log2(x) / @math.log10(x)
@math.floor / ceil / round
```

## 9. 进程退出码（CLI 必须）

```moonbit
// moonbitlang/x/sys
@sys.exit(0)    // 成功
@sys.exit(1)    // 数据错误
@sys.exit(2)    // 用法错误
```
`fn main` 只能返回 Unit，退出码靠 `@sys.exit`。

## 10. 浮点测试的三个坑（**必读，会浪费你很多时间**）

### 坑 A：不支持科学计数法字面量

```moonbit
assert_true(x < 1e-9)          // ❌ Parse error
assert_true(x < 0.000000001)   // ✅
```

### 坑 B：`inspect` 对 Double 是精确字符串比对

```moonbit
inspect(ef[0], content="2.6")   // ❌ 实际是 "2.6" 但 2.7 会变成 "2.7000000000000003"
inspect(x, content="2.8000000000000003")  // ❌ 又脆又丑
```

**正确做法：用容差断言，不要用 `inspect` 比浮点。**

```moonbit
let d = ef[0] - 2.6
assert_true(d.abs() < 0.000000001)
```

### 坑 C：表达式里直接比较可能解析失败

```moonbit
// ❌ 有时解析器不接受
assert_true((ef[0] - 2.6).abs() < 0.000000001)
// ✅ 先绑定到变量
let d = ef[0] - 2.6
assert_true(d.abs() < 0.000000001)
```

### 坑 D：位运算优先级

```moonbit
if (mask >> i) & 1 == 0 { }        // ❌ Expr Type Mismatch
if ((mask >> i) & 1) == 0 { }      // ✅ 位运算必须自己加括号
```

### 坑 E：枚举比较需要 Eq

```moonbit
pub(all) enum R { Ok; Val(Int) } derive(Debug)      // ❌ expected == op.result 报错
pub(all) enum R { Ok; Val(Int) } derive(Eq, Debug)  // ✅
```

## 11. 更多实测坑（由多位开发者汇总）

```moonbit
// derive(Debug) 不含 Show，inspect 打印不了枚举/结构体
inspect(my_enum, content="...")     // ❌ 需要 Show
// ✅ 先转 String 或用 == 比 Bool
inspect(my_enum.label(), content="x")
inspect(a == b, content="true")

// 包内顶层函数只能定义一次（哪怕在不同测试文件）
// test_helpers_test.mbt 里放共享的 approx()，其他测试文件直接调用

// trait 方法要显式限定，否则 deprecation
s.name()                    // ⚠️ implicit promotion
Scheduler::name(s)          // ✅

// @math 没有 abs
x.abs()                     // ✅ Double::abs()

// 没有 ? 后缀（try 运算符）
let x = f()?                // ❌
let x = f()                 // ✅ 直接 raise 穿透

// 没有 String * n
String::make(30, ' ')       // ✅ 重复字符

// 不支持 for &x in arr
for x in arr.iter()         // ✅

// 记录字段默认不可变，mut 加在字段上也没用
cli.json = true                     // ❌ The record field json is immutable
let cli2 = { ..cli, json: true }    // ✅ 用结构体更新语法
// 例外：struct R { mut state : Int } 可以改 self.state

// 多行 && 在 if 里不能直接换行
if a
   && b { }                 // ❌ Unexpected line break
let ok = a && b             // ✅
if ok { }

// 结构体不支持 trait 约束
struct Ctx[M : Model] { }   // ❌ Parse error
// 泛型只加在函数上：fn[M : Model] dfs(model : M, ...)

// 枚举变体只能用位置参数
suberror E { V(line : Int) }  // ❌
suberror E { V(Int) }         // ✅

// 结构体和同名枚举变体冲突时
Violation({ ... })          // ❌ 被解析成 CheckOutcome 的变体
Violation::{ ... }          // ✅

// guard 是保留字
fn f(guard : Expl)          // ❌ Parse error

// 空 import {} + options() 要小心 mnemonic 拼写
// warn_list 里写错 mnemonic 是**硬失败**，不是警告
// 合法示例: "-implicit_impl_as_method-unused_package-deprecated"
```

## 12. PowerShell 辅助脚本的坑

```powershell
# -eq 对数组是「过滤」不是「比较」
if ($a -eq $b) { }          # ❌ 永远为真/假得莫名其妙
if (($a | Out-String) -ceq ($b | Out-String)) { }   # ✅

# curl 的 -s 后面不能跟空参数
```

## 13. 最终检查清单（提交前）

```powershell
$env:MOON_HOME="E:\moonbit\home"; $env:Path="E:\moonbit\home\bin;"+$env:Path
moon check          # 0 error
moon test           # 全绿
moon fmt            # 格式化
moon info           # 生成 .mbti 接口文件
moon build --target wasm
```

## 14. 常见坑汇总

| 现象 | 原因 / 解法 |
|---|---|
| `unused_mut` 报错 | `Array`/`StringBuilder` 的方法不需要 `mut` 绑定 |
| `The type X is undefined` | 没在 `moon.pkg` 里 import |
| `core_package_not_imported` | 同上，新版要求显式 import |
| `Cannot create values of the read-only type` | 结构体要 `pub(all)` |
| `Unknown variant lib` | `pkgtype` 用 `library` |
| `Cannot find import 'a/b'` | 包路径要写 `模块名/src` |
| `Function with error is not allowed in fn main` | 写成 `fn main raise` |
| `{}` 歧义警告 | 用 `Map([])` / `Json::empty_object()` |
| `derive(Show)` 弃用 | 用 `derive(Debug)`；数组用 `\{...}` 插值需元素实现 `Show` |
| `is a trait, not a type` | MoonBit 无 trait object，用泛型约束或枚举包装 |
| `1e-9` Parse error | 不支持科学计数法，写 `0.000000001` |
| `Int` 溢出成负数 | 32 位有符号，LCG 乘法后要 `& 0x7FFFFFFF` |
| 位运算比较报类型错 | 加括号：`((a >> b) & 1) == 0` |
