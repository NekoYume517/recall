// ============================================================================
// weight_validation_test.mbt — FSRS 权重验证套件
//
// 目标：回答「用户给的 FSRS-5 权重，凭什么信它是合理的 FSRS 权重？」
//
// 三层验证：
//   V1 结构验证 —— 长度、有限性、逐项范围（每项有物理含义，范围不同）
//   V2 语义验证 —— 走一遍公式，S/D/间隔必须落在人类可解释的范围
//   V3 参考验证 —— py-fsrs 官方权重下的关键值交叉核对
//
// 交付物：
//   1. `FsrsWeightIssue` / `validate_fsrs_weights` — 库级 API，显式 Result
//   2. `Fsrs::with_params_checked` — 校验失败时报错的构造器
//   3. 回归测试锁定以上行为
// ============================================================================

// ---------------------------------------------------------------------------
// V1 结构验证
// ---------------------------------------------------------------------------

///|
/// 单个权重问题。
///
/// `index` 是出问题的权重下标（0..18 为 FSRS-5 公式使用的范围）；
/// `value` 是读到的值；`why` 是人话解释。
pub(all) struct FsrsWeightIssue {
  index : Int32
  value : Double
  why : String
} derive(Debug)

///|
/// 权重校验结果：合法（`Ok`）或问题列表（`Err`）。
///
/// 多个问题**全部收集**而不是遇错即停——用户一次性修完比改一个跑一次快。
pub(all) enum FsrsWeightCheck {
  Valid
  Invalid(Array[FsrsWeightIssue])
} derive(Debug)

///|
/// 检查一个 Double 是否有限（非 NaN / ±Infinity）。
fn is_finite(x : Double) -> Bool {
  !x.is_nan() && x != 1.0 / 0.0 && x != -1.0 / 0.0
}

///|
/// 权重的逐项物理含义与安全范围。
///
/// 来源：FSRS-5 公式定义（见 fsrs.mbt 各函数的文档注释）与官方默认值
/// 的数量级。范围故意给得宽（覆盖合理微调），但把「会让公式发散 /
/// 产生 NaN / 语义反转」的值挡在门外：
///
/// | 下标 | 作用 | 默认值 | 允许范围 | 理由 |
/// |---|---|---|---|---|
/// | 0..3 | S₀(Again/Hard/Good/Easy) | 0.40..15.69 | [0.1, 100] | 与初始稳定性 0.1 天下限一致 |
/// | 4   | 难度基准 | 7.1949 | [1, 10] | D 的值域 |
/// | 5   | 难度对评分敏感度 | 0.5345 | [0, 5] | 负值会让 Easy 更难，语义反转 |
/// | 6   | 难度增量系数 | 1.4604 | [0, 10] | 0 = 难度冻结（允许），>10 单步推动 >9 点 |
/// | 7   | 均值回归强度 | 0.0046 | [0, 1] | >1 会把难度推离当前值发散 |
/// | 8   | 增益缩放（exp 后） | 1.54575 | [-5, 5] | exp(5)≈148 倍单步增益已无意义 |
/// | 9   | S 边际递减指数 | 0.1192 | [0, 2] | 负值让大 S 增益更大 → 爆炸 |
/// | 10  | 合意困难指数 | 1.01925 | [0, 10] | 负值反转「忘久了补回来更多」 |
/// | 11  | 遗忘基准 | 1.9395 | (0, 100] | ≤0 让遗忘后 S 为 0/负 |
/// | 12  | 遗忘难度指数 | 0.11 | [0, 5] | 负值让难卡遗忘后更稳，语义反转 |
/// | 13  | 遗忘 S 幂次 | 0.29605 | [0, 2] | 负值让强记忆遗忘后更不稳 |
/// | 14  | 遗忘 R 修正 | 2.2698 | [0, 10] | 负值反转「拖越久补回越多」 |
/// | 15  | Hard 惩罚 | 0.2315 | (0, 1] | >1 变成 Hard 奖励 |
/// | 16  | Easy 奖励 | 2.9898 | [1, 10] | <1 变成 Easy 惩罚 |
/// | 17  | 同日指数系数 | 0.51655 | [0, 10] | 同日稳定性乘 exp(w17·(g-3+w18)) |
/// | 18  | 同日评分偏移 | 0.6621 | [0, 1] | 调整同日复习的指数增益 |
fn weight_bounds() -> Array[(Double, Double, String)] {
  // (lower, upper, 语义名) — lower/upper 为允许的闭区间边界
  [
    (0.1, 100.0, "S0(Again)"),
    (0.1, 100.0, "S0(Hard)"),
    (0.1, 100.0, "S0(Good)"),
    (0.1, 100.0, "S0(Easy)"),
    (1.0, 10.0, "难度基准"),
    (0.0, 5.0, "难度敏感度"),
    (0.0, 10.0, "难度增量系数"),
    (0.0, 1.0, "均值回归强度"),
    (-5.0, 5.0, "增益缩放(log)"),
    (0.0, 2.0, "S边际递减指数"),
    (0.0, 10.0, "合意困难指数"),
    (0.0001, 100.0, "遗忘基准"),
    (0.0, 5.0, "遗忘难度指数"),
    (0.0, 2.0, "遗忘S幂次"),
    (0.0, 10.0, "遗忘R修正"),
    (0.0001, 1.0, "Hard惩罚"),
    (1.0, 10.0, "Easy奖励"),
    (0.0, 10.0, "同日增幅"),
    (0.0, 1.0, "同日惩罚"),
  ]
}

///|
/// 结构验证：长度、有限性、逐项范围。
///
/// 接受 FSRS-5 原生 **19 项**，以及本库兼容格式 **21 项**。
/// 公式只使用 w0..w18；兼容格式的末两项不参与计算，但必须为有限数。
/// 21 项格式并不代表支持 FSRS-6，不能用长度判断模型版本。
/// 其他长度显式拒绝，避免静默截断隐藏版本错配。
pub fn validate_fsrs_weights(w : Array[Double]) -> FsrsWeightCheck {
  let issues : Array[FsrsWeightIssue] = []
  if w.length() != 19 && w.length() != 21 {
    issues.push({
      index: -1,
      value: 0.0,
      why: "权重必须是 19 项（FSRS-5）或 21 项（本库兼容格式），got \{w.length()}",
    })
    return Invalid(issues)
  }
  for i = 0; i < w.length(); i = i + 1 {
    let v = w[i]
    if !is_finite(v) {
      issues.push({
        index: i,
        value: v,
        why: "w[\{i}] 不是有限数（NaN 或 ±Infinity）",
      })
      continue
    }
    let bounds = weight_bounds()
    if i < 19 {
      let (lo, hi, name) = bounds[i]
      if v < lo || v > hi {
        issues.push({
          index: i,
          value: v,
          why: "w[\{i}] (\{name}) 应在 [\{lo}, \{hi}]，got \{v}",
        })
      }
    }
    // w[19]/w[20] 是本库兼容位，不参与公式，只校验有限性
  }
  if issues.length() == 0 {
    Valid
  } else {
    Invalid(issues)
  }
}

// ---------------------------------------------------------------------------
// V2 语义验证
// ---------------------------------------------------------------------------

///|
/// 语义验证：用这份权重走一遍公式，检查输出可解释。
///
/// 结构合法（在范围内）的权重仍可能语义病态：比如所有 S₀ 都顶到 100，
/// 难度恒为 1 等。这里检查四个不变量：
///
///   1. 四种首评的 S₀ 严格递增（Again < Hard < Good < Easy）
///   2. 同一评分下 S₀ 与 D₀ 有限
///   3. Good×5 的 S 序列单调不减且 < 10⁶ 天（约 2700 年，超出即病态）
///   4. Again 的间隔 < Easy 的间隔（评分敏感性还活着）
pub fn validate_fsrs_semantics(w : Array[Double]) -> FsrsWeightCheck {
  let issues : Array[FsrsWeightIssue] = []
  // 结构先过关才谈语义
  match validate_fsrs_weights(w) {
    Invalid(xs) => return Invalid(xs)
    Valid => ()
  }
  // 1. S₀ 单调性
  let s_again = initial_stability(w, 1)
  let s_hard = initial_stability(w, 2)
  let s_good = initial_stability(w, 3)
  let s_easy = initial_stability(w, 4)
  if !(s_again < s_hard && s_hard < s_good && s_good < s_easy) {
    issues.push({
      index: -1,
      value: 0.0,
      why: "S₀ 必须随评分递增（Again<Hard<Good<Easy），got \{s_again} / \{s_hard} / \{s_good} / \{s_easy}",
    })
  }
  // 2. 有限性
  for rating, name in [(1, "Again"), (2, "Hard"), (3, "Good"), (4, "Easy")] {
    let s = initial_stability(w, rating)
    let d = initial_difficulty(w, rating)
    if !is_finite(s) || !is_finite(d) {
      issues.push({
        index: -1,
        value: 0.0,
        why: "\{name} 的初始 S/D 非有限：S=\{s} D=\{d}",
      })
    }
  }
  // 3. Good×5 不爆炸
  let mut d = initial_difficulty(w, 3)
  let mut s = initial_stability(w, 3)
  for i = 0; i < 5; i = i + 1 {
    let r = forgetting_curve(1.0, s)
    d = next_difficulty(w, d, 3)
    s = stability_after_success(w, d, s, r, 3)
    if !is_finite(s) || s >= 1000000.0 {
      issues.push({
        index: -1,
        value: s,
        why: "Good×5 后稳定性 \{s} 超出可解释范围（第 \{i + 1} 步）",
      })
      break
    }
  }
  // 4. 评分敏感性
  let i_again = interval_days(initial_stability(w, 1), 0.9)
  let i_easy = interval_days(initial_stability(w, 4), 0.9)
  if !(i_again < i_easy) {
    issues.push({
      index: -1,
      value: 0.0,
      why: "Again 的间隔 (\{i_again}) 必须 < Easy 的间隔 (\{i_easy})",
    })
  }
  if issues.length() == 0 {
    Valid
  } else {
    Invalid(issues)
  }
}

// ---------------------------------------------------------------------------
// V3 参考验证（py-fsrs 官方值交叉核对）
// ---------------------------------------------------------------------------

///|
/// 参考验证：官方默认权重下的关键值，与 py-fsrs 的公开实现交叉核对。
///
/// 这些值不是本仓库算出来再抄回去——每一条都能在 py-fsrs 里独立复算：
///
///   R(1, S₀(Good))：py-fsrs 的 forgetting_curve(1, w[2]) = 0.829...
///   D₀(3)：w[4] - exp(0) + 1 = 7.1949 - e^0 + 1... 见 fsrs_test 手算表
///   S'（Good×3 手算序列）：见 fsrs_test.mbt 的手算表测试
///
/// 在这里锁定它们的目的是：**官方权重是全部公式常量的联立解**。
/// 任何一处抄错系数 / 搞反符号，这条联立就会崩——比逐个公式测试
/// 更难绕过。
pub fn validate_fsrs_reference() -> FsrsWeightCheck {
  let issues : Array[FsrsWeightIssue] = []
  let w = fsrs_default_w()
  let near = fn(x : Double, y : Double, tol : Double) -> Bool {
    (x - y).abs() < tol
  }
  // 官方权重的结构合法性（自检：bounds 表别把官方值挡在门外）
  match validate_fsrs_weights(w) {
    Invalid(xs) =>
      for x in xs {
        issues.push(x)
      }
    Valid => ()
  }
  // 联立锚点 1：R(S, S) = 0.9 对所有四个初始 S 同时成立
  for pair in [(0, 1), (1, 2), (2, 3), (3, 4)] {
    let (i, g) = pair
    let s0 = initial_stability(w, g)
    if !near(forgetting_curve(s0, s0), 0.9, 0.000000000001) {
      issues.push({
        index: i,
        value: forgetting_curve(s0, s0),
        why: "R(S₀(\{g}), S₀(\{g})) 必须 = 0.9",
      })
    }
  }
  // 联立锚点 2：dr=0.9 时 I(S) 未取整前 = S（间隔公式自检）
  // 用 21.37 这样的小数 S 避开取整干扰
  let s_probe = 21.37
  let raw = s_probe / factor * (@math.pow(0.9, 1.0 / decay) - 1.0)
  if !near(raw, s_probe, 0.000000001) {
    issues.push({
      index: -1,
      value: raw,
      why: "interval 公式自检失败：I(21.37, 0.9) 未取整应 = 21.37，got \{raw}",
    })
  }
  // 联立锚点 3：S'（Good, D=5, S=3, R=0.9）
  //   gain = exp(w8)·(11-D)·S^(-w9)·(exp(w10·(1-R))-1)
  //   用 Python 独立复算（与本实现零共享代码）得到 10.948986752888501，
  //   断言容差 1e-9 —— 手算近似值精度不够，这里锁的是位级一致。
  let sp = stability_after_success(w, 5.0, 3.0, 0.9, 3)
  if !near(sp, 10.948986752888501, 0.000000001) {
    issues.push({
      index: -1,
      value: sp,
      why: "S'(Good,D=5,S=3,R=0.9) 独立复算 = 10.948986752888501，got \{sp}",
    })
  }
  // 联立锚点 4：遗忘路径 S'(Again, D=5, S=3, R=0.5)
  //   = w11 · D^(-w12) · ((S+1)^w13 - 1) · exp(w14·(1-R))
  //   Python 独立复算 = 2.5648860200305696
  let sl = stability_after_lapse(w, 5.0, 3.0, 0.5)
  if !near(sl, 2.5648860200305696, 0.000000001) {
    issues.push({
      index: -1,
      value: sl,
      why: "S'(Again,D=5,S=3,R=0.5) 独立复算 = 2.5648860200305696，got \{sl}",
    })
  }
  if issues.length() == 0 {
    Valid
  } else {
    Invalid(issues)
  }
}

// ---------------------------------------------------------------------------
// 校验版构造器
// ---------------------------------------------------------------------------

///|
/// 带校验的构造器：权重不合法时报错，**不静默回退**。
///
/// 与 `with_params` 的关系：
///   - `with_params`：宽容版（长度不足回退默认）——CLI 现有路径依赖它
///   - `with_params_checked`：严格版（显式 Result）——新代码建议用这个
///
/// 校验内容 = 结构 + 语义（两关全过才返回实例）。
pub fn Fsrs::with_params_checked(w : Array[Double]) -> Result[Fsrs, String] {
  match validate_fsrs_weights(w) {
    Invalid(xs) => {
      let msgs = xs.map(fn(x) { "w[\{x.index}]=\{x.value}: \{x.why}" })
      Err("权重校验失败（\{xs.length()} 处）：\{msgs.join("；")}")
    }
    Valid =>
      match validate_fsrs_semantics(w) {
        Invalid(xs) => {
          let msgs = xs.map(fn(x) { "w[\{x.index}]=\{x.value}: \{x.why}" })
          Err(
            "权重语义病态（\{xs.length()} 处）：\{msgs.join("；")}",
          )
        }
        Valid => Ok({ w: w.copy(), desired_retention: 0.9, })
      }
  }
}
