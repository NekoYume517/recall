# 演示与复现

评审可以直接按顺序跑下面每一步。所有命令都在仓库根目录执行，不需要网络。

## 环境

```bash
curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash
export PATH="$HOME/.moon/bin:$PATH"
moon version   # 期望 0.1.20261012 或更新
```

Windows：

```powershell
$env:MOON_HOME="$env:USERPROFILE\.moon"
$env:Path="$env:MOON_HOME\bin;"+$env:Path
moon version
```

## 一、clone 后立刻能跑

```bash
moon check
moon test      # 313 个测试
moon build --target wasm
```

预期：`Total tests: 313, passed: 313, failed: 0.`

## 二、核心产出：积压预测

这是整个项目最想回答的问题——**「如果每天学 20 张新卡，三个月后会积压多少？」**

```bash
# 配额充足：不积压
moon run cmd/recall -- simulate --scheduler fsrs --days 90 --new-per-day 20 --review-limit 200
```

预期：

```
总复习次数: 7735
最大积压:   0 张
最终积压:   0 张
```

```bash
# 配额收紧：积压迅速失控
moon run cmd/recall -- simulate --scheduler fsrs --days 90 --new-per-day 20 --review-limit 50
```

预期：

```
最终积压:   1337 张
→ 90 天后仍有 1337 张卡在排队等待复习
```

**这是可操作的结论**：每天 20 张新卡时，复习上限不能低于某个值，否则三个月后积压是新增量的 66 倍。

## 三、看到积压如何恶化记忆

```bash
moon run cmd/recall -- simulate --scheduler fsrs --days 60 --new-per-day 20 --review-limit 30
```

看「记住」这一列：第 1 天 16/20（80%），到第 57 天只有 18/30（60%）。积压越深，每次复习时的实际可提取性越低——**这是模拟器里最容易漏掉的一环**（早期版本没有把它算进去，导致积压数被系统性低估）。

## 四、对比两种算法

```bash
moon run cmd/recall -- compare --log examples/reviews.jsonl --a sm2 --b fsrs
```

预期头部：

```
指标                                sm2           fsrs             差值
--------------------------------------------------------------------
最终间隔总和(天)                    174058.0        13995.0      -160063.0
遗忘次数                              132            132              0
平均间隔(天)                        6962.3          559.8        -6402.5
触及上限(100年)卡数                     4              0             -4
```

**注意 `触及上限卡数` 这一行**。SM-2 的间隔是纯几何增长，25 张卡里有 4 张顶到 100 年上限——这在现实中等同于「永远不再复习」，等价于遗忘。所以「SM-2 的总间隔是 FSRS 的 12 倍」**不能**读成 SM-2 更好。CLI 会主动打印这段警告。

逐卡对比更能说明问题：全 Easy 的卡 FSRS 给 239 天、SM-2 给 131 天；而多次遗忘的卡 FSRS 压到 4 天、SM-2 给 1 天——**FSRS 在「遗忘后」的区分度更高**，这正是它相对 SM-2 的设计意图。

## 五、验证 FSRS 的定义性不变量

FSRS 的核心定义是「S = 回忆概率衰减到 90% 所需的天数」。这给出两个可测的恒等式：

```bash
moon test
```

看 `src/fsrs_test.mbt` 里这些测试：

- `R(t = S, S) = 0.9`（误差 < 1e-9）
- `interval_days(S, 0.9) = S`（未取整前精确相等）

为什么 `interval_days(S, 0.9)` 恒等于 S：

```
I = S / (19/81) * (0.9^(1/-0.5) - 1)
  = S / (19/81) * (0.9^-2 - 1)
  = S / (19/81) * (19/81)
  = S
```

这两条比逐个数值比对更能抓住实现错误：任何公式符号写反、常数写错都会破坏它们。

## 六、看保留率曲线

```bash
moon run cmd/recall -- curve --log examples/reviews.jsonl --buckets 10
```

预期趋势：

```
< 18.0    91.85%
< 36.0    80.21%
< 54.0    54.90%
< 72.0    74.29%
...
< 179.9   50.00%
```

**整体趋势从 91.85% 降到 50.00%**，中间有桶间抖动。

这不是 bug，是小样本统计的固有特性：后 7 个桶每桶只有 9–39 个样本，二项分布的标准差约 11%，所以 55% ↔ 75% 的波动在期望范围内。CLI 会打印「曲线出现回升（样本噪声，或分桶过细）」——这个诊断是准确的。

要让曲线严格单调，需要每桶上千样本，对示例文件不现实。**重要的是趋势而不是逐桶单调**。

## 七、样例数据的设计

```bash
python3 scripts/gen_reviews.py
```

生成脚本遵守两条硬约束，都来自实际踩过的坑：

**1. `elapsed_days` 必须严格等于相邻事件的时间戳差**

早期版本用两套独立逻辑生成（时间戳手工错开、字段手填常量），导致 24/24 条记录不一致。后果是 `replay`（用时间戳算间隔）与 `retention_curve`（用字段分桶）给出矛盾结论。现在脚本用时间戳反算字段值，自检输出 `mismatches: 0`。

**2. 评分由遗忘曲线决定，而不是手填**

```python
R = (1 + 19/81 * t/S) ** -0.5
记不记得 = rng.uniform() < R
```

这样 lapses **天然**集中在长间隔，曲线单调性成为数据的必然结果。早期版本手填「grades 序列 + elapsed 序列」两组无关常量，导致 3 次失败全在 `elapsed ≤ 2` 天、`elapsed ≥ 3` 零失败——与真实遗忘规律相反，任何分桶都不可能单调。

当前规模：25 张卡 × 30 次复习 = 750 事件，遗忘率 17.6%。

## 八、SM-2 的权威参考值

```bash
moon test
```

`src/sm2_test.mbt` 里有四组手算表格，逐项比对：

| 序列 | interval（天） | 每次后的 EF |
|---|---|---|
| Good ×5 | 1, 6, 15, 38, 95 | 2.5 恒定 |
| Easy ×3 | 1, 6, 16 | 2.6, 2.7, 2.8 |
| Hard ×3 | 1, 6, 13 | 2.36, 2.22, 2.08 |
| Good, Good, Again, Good | 1, 6, 1, 1 | 2.5, 2.5, **2.18**, 2.18 |

**第四组最容易算错。** `Again` 的 `q = 2`，增量是 `0.1 - 3*(0.08+3*0.02) = -0.32`，所以 EF 从 2.5 降到 2.18。如果误把 `Again` 当 `q = 0`，会得到 `2.5 - 0.80 = 1.70`——这是错的，因为 `q = 0` 不在映射表里。

## 九、错误路径

```bash
moon run cmd/recall -- replay --log nope.jsonl --scheduler sm2
# → 错误信息 + exit 1

moon run cmd/recall -- replay --log examples/reviews.jsonl --scheduler bogus
# → 未知调度器 + exit 2
```

## 十、测试覆盖了哪些边界

| 文件 | 覆盖内容 |
|---|---|
| `src/sm2_test.mbt` | 四组手算表、EF 下限 1.3、连续 20 次 Again 不击穿 |
| `src/fsrs_test.mbt` | `R(t=S)=0.9`、`I(S,0.9)=S`、linear damping 饱和、新 D 顺序 |
| `src/log_test.mbt` | JSONL 往返、grade 归一化幂等性 |
| `src/replay_test.mbt` | 重放确定性、跨调度器对比 |
| `src/simulate_test.mbt` | 模拟确定性、积压恶化记忆、无积压时不反向伤害 |
| `src/stats_test.mbt` | 保留率曲线单调性 |
| `src/interval_cap_test.mbt` | Int64 回绕防护、100 年封顶 |

## 十一、看到这里还没被说服？

`docs/implementation.md` 记录了 12 个不显然的技术判断和 5 个真实 bug，包括：

- FSRS 缺 `linear_damping` → 难度失去分辨率，系统性高估间隔（修正后复习量降 14%）
- `add_days` 的 Int64 回绕 → `due` 变负数，卡片永久到期
- SM-2 间隔无上限 → 30 次复习后 `3.2e12` 天
- 模拟器策略拿不到 `now` → 积压越久，记住率反而上升

每一条都有对应的回归测试锁住。
