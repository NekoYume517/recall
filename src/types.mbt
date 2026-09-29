// recall — 基础类型
//
// 合同：API.md 第 1 节。公开签名不得更改。
// 这里额外提供了少量纯函数工具（天数换算、CardState 构造函数），
// 供 replay / simulate / stats / CLI 复用，避免每个文件各自算 86400。

///|
/// 评分：0=完全忘记，1=困难，2=犹豫，3=良好，4=轻松，5=完美
///
/// 注意：`to_int` 给出的是「展示用」的 0..5 刻度（Again=0 / Hard=2 /
/// Good=3 / Easy=5），**不是** SM-2 公式里的 `q`。SM-2 的 `q` 另有映射
/// （Again=2 / Hard=3 / Good=4 / Easy=5），见 `sm2.mbt` 的 `sm2_quality`。
pub(all) enum Grade {
  Again // 0
  Hard // 1-2
  Good // 3
  Easy // 4-5
} derive(Eq, Debug)

///|
/// 评分 → 展示用整数（Again=0 / Hard=2 / Good=3 / Easy=5）。
pub fn Grade::to_int(self : Grade) -> Int {
  match self {
    Again => 0
    Hard => 2
    Good => 3
    Easy => 5
  }
}

///|
/// 整数 → 评分。超出 0..5 的输入夹到两端：
/// `0→Again, 1|2→Hard, 3→Good, 4|5→Easy`，负数按 0、>5 按 5 处理。
pub fn Grade::from_int(n : Int) -> Grade {
  if n <= 0 {
    Again
  } else if n <= 2 {
    Hard
  } else if n == 3 {
    Good
  } else {
    Easy
  }
}

///|
/// 是否成功回忆 —— **全项目唯一的「答对/答错」判定**。
///
/// 等价于 `g != Again`。也就是：
///   - Again → 没想起来（失败）
///   - Hard / Good / Easy → 想起来了（成功，哪怕很吃力）
///
/// 为什么不是 `to_int() >= 3`：那样会把 Hard（to_int = 2）判成失败，
/// 但 SM-2 的答错判定是 `q < 3`，而 Hard 的 q = 3，属于**答对**。
/// 学习理论上 Hard 也明确表示"回忆成功但吃力"。
///
/// `stats` / `simulate` / `replay` / 各调度器都必须调用这个函数，
/// 不要各自再实现一遍（曾经各写一份导致 Leitner 和 SM-2 判定不一致）。
pub fn is_recalled(g : Grade) -> Bool {
  g != Again
}

///|
/// 【已弃用别名】保留只是为了不打断既有调用点，请改用 `is_recalled`。
///
/// 名字 "pass" 有误导性：它听起来像"及格"，而学习理论里
/// Hard 是及格的（回忆成功），只是吃力。历史上这里实现成
/// `to_int >= 3` 是 bug，已修正为委托 `is_recalled`。
pub fn Grade::is_pass(self : Grade) -> Bool {
  is_recalled(self)
}

///|
/// 评分的稳定小写标签，供 CLI / JSON 报告使用。
pub fn Grade::label(self : Grade) -> String {
  match self {
    Again => "again"
    Hard => "hard"
    Good => "good"
    Easy => "easy"
  }
}

///|
/// 标签 → 评分。未知标签返回 `None`（不做猜测，避免 CLI 静默误判）。
pub fn Grade::from_label(name : StringView) -> Grade? {
  match name {
    "again" => Some(Again)
    "hard" => Some(Hard)
    "good" => Some(Good)
    "easy" => Some(Easy)
    _ => None
  }
}

///|
/// 秒级时间戳（Unix epoch），避免浮点。`Int64` 别名。
pub type Timestamp = Int64

///|
/// 一天的秒数。上下文里到处要 86400，集中一处。
pub fn seconds_per_day() -> Double {
  86400.0
}

///|
/// 两个时间戳之间相差多少天（可正可负）。
pub fn days_between(from : Timestamp, to : Timestamp) -> Double {
  (to - from).to_double() / seconds_per_day()
}

///|
/// 从时间戳往后推 `days` 天，四舍五入到整秒。
pub fn add_days(now : Timestamp, days : Double) -> Timestamp {
  now + @math.round(days * seconds_per_day()).to_int64()
}

///|
/// 卡片记忆状态。
///
/// 字段含义（跨调度器共享的容器）：
/// - `stability`   S：保持天数（FSRS 直接使用；SM-2/Leitner 存当前间隔的镜像）
/// - `difficulty`  D：1..10（FSRS 直接使用；SM-2 借它保存 EF；Leitner 借它保存盒号）
/// - `reps`        累计成功复习次数
/// - `lapses`      遗忘（答错）次数
/// - `last_review` 上次复习时刻
/// - `due`         下次到期时刻
/// - `interval_days` 当前间隔天数
/// - `phase`       生命周期阶段
pub(all) struct CardState {
  card_id : String
  stability : Double // S：保持天数
  difficulty : Double // D：1..10
  reps : Int // 成功复习次数
  lapses : Int // 遗忘次数
  last_review : Timestamp
  due : Timestamp
  interval_days : Double
  phase : Phase
} derive(Debug)

///|
/// 卡片生命周期：
/// - `New`        从未复习
/// - `Learning`   学习期内（短间隔）
/// - `Review`     长期复习（间隔已拉长）
/// - `Relearning` 遗忘后重新学习
pub(all) enum Phase {
  New
  Learning
  Review
  Relearning
} derive(Eq, Debug)

///|
/// 阶段的中文标签，供 CLI 报表使用。
pub fn Phase::label(self : Phase) -> String {
  match self {
    New => "新卡"
    Learning => "学习中"
    Review => "复习"
    Relearning => "重学"
  }
}

///|
/// 白板状态：一切归零，`due` 就是 `now`（立即可复习）。
pub fn CardState::new(card_id : String, now : Timestamp) -> CardState {
  {
    card_id,
    stability: 0.0,
    difficulty: 0.0,
    reps: 0,
    lapses: 0,
    last_review: now,
    due: now,
    interval_days: 0.0,
    phase: New,
  }
}

///|
/// 是否从未复习过。
pub fn CardState::is_new(self : CardState) -> Bool {
  self.reps == 0 && self.lapses == 0 && self.last_review == self.due
}

///|
/// 在 `now` 这个时刻是否已到期（可复习）。
pub fn CardState::is_due(self : CardState, now : Timestamp) -> Bool {
  self.due <= now
}

///|
/// 已逾期天数（未到期返回 0）。
pub fn CardState::overdue_days(self : CardState, now : Timestamp) -> Double {
  let d = days_between(self.due, now)
  if d > 0.0 {
    d
  } else {
    0.0
  }
}

///|
/// 状态相等（CardState 只有 derive(Debug)，逐字段手写比较）。
/// 浮点用精确比较：状态由确定性算法产生，不需要容差。
pub fn CardState::equal(a : CardState, b : CardState) -> Bool {
  a.card_id == b.card_id &&
  a.stability == b.stability &&
  a.difficulty == b.difficulty &&
  a.reps == b.reps &&
  a.lapses == b.lapses &&
  a.last_review == b.last_review &&
  a.due == b.due &&
  a.interval_days == b.interval_days &&
  a.phase == b.phase
}
