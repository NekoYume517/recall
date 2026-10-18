// recall CLI
//
// 合同：API.md 第 7 节。
//
//   recall replay   --log <file.jsonl> --scheduler sm2|fsrs|leitner [--json]
//   recall compare  --log <file.jsonl> --a sm2 --b fsrs
//   recall simulate --scheduler fsrs --days 90 --new-per-day 20 --review-limit 200 --policy realistic
//   recall stats    --log <file.jsonl>
//   recall curve    --log <file.jsonl> --buckets 10
//
// 退出码：0 成功 / 1 数据错误 / 2 用法错误。
//
// 实现说明：
// - 手写参数解析（`--key value` / `--flag`），不引 argparse——
//   依赖越少，CLI 越不容易因为版本漂移而坏。
// - MoonBit 的 `fn main` 只能返回 Unit，退出码靠 `@sys.exit`。
// - MoonBit 不支持多行字符串字面量，用法文本用数组拼。

// ---------------------------------------------------------------------------
// 参数解析
// ---------------------------------------------------------------------------

///|
/// 解析后的命令行参数。
struct Args {
  /// `--key value` 形式
  params : Map[String, String]
  /// `--flag` 形式（无值）
  flags : Map[String, Bool]
}

///|
/// 手写解析：遇到 `--xxx` 就看下一项是否以 `--` 开头，
/// 不是则当作值，是则记成布尔 flag。
fn parse_args(argv : Array[String]) -> Args {
  let params : Map[String, String] = Map([])
  let flags : Map[String, Bool] = Map([])
  let mut i = 0
  while i < argv.length() {
    let tok = argv[i]
    if tok.has_prefix("--") {
      let body = tok.substring(start=2, end=tok.length())
      let has_next = i + 1 < argv.length()
      if has_next && !argv[i + 1].has_prefix("--") {
        params[body] = argv[i + 1]
        i = i + 2
      } else {
        flags[body] = true
        i = i + 1
      }
    } else {
      // 位置参数忽略（子命令已在 main 里取走）
      i = i + 1
    }
  }
  { params, flags, }
}

///|
fn Args::get(self : Args, key : String, fallback : String) -> String {
  match self.params.get(key) {
    Some(v) => v
    None => fallback
  }
}

///|
/// 参数存在性查询：None = 未提供，Some = 提供了（可能值不合法）。
/// 数值参数需要区分这两种情况——前者用默认值，后者报用法错误。
fn Args::get_opt(self : Args, key : String) -> String? {
  self.params.get(key)
}

///|

///|
fn Args::has(self : Args, key : String) -> Bool {
  match self.params.get(key) {
    Some(_) => true
    None =>
      match self.flags.get(key) {
        Some(_) => true
        None => false
      }
  }
}

// ---------------------------------------------------------------------------
// 宽松的数字解析（不抛异常，非法值返回 None）
//
// moonbitlang/core/string 的 parse_* 是 `raise` 风格，
// 在 CLI 里到处 try/catch 很啰嗦，这里自己实现一份"探测式"解析。
// ---------------------------------------------------------------------------

///|
fn digit_of(c : UInt16) -> Int32 {
  if c >= '0' && c <= '9' {
    c.to_int() - 48
  } else {
    -1
  }
}

///|
/// 解析整数。允许前导 +/−，不允许其它字符。
fn parse_int_loose(s : String) -> Int32? {
  let t = s.trim_space().to_owned()
  if t.length() == 0 {
    return None
  }
  let mut i = 0
  let mut neg = false
  if t[0] == '-' {
    neg = true
    i = 1
  } else if t[0] == '+' {
    i = 1
  }
  if i >= t.length() {
    return None
  }
  let mut acc : Int64 = 0L
  while i < t.length() {
    let dg = digit_of(t[i])
    if dg < 0 {
      return None
    }
    acc = acc * 10L + dg.to_int64()
    i = i + 1
  }
  if neg {
    Some((-acc).to_int())
  } else {
    Some(acc.to_int())
  }
}

///|
/// 解析浮点。支持 `1`、`1.5`、`-0.25`、`+2.`。
fn parse_double_loose(s : String) -> Double? {
  let t = s.trim_space().to_owned()
  if t.length() == 0 {
    return None
  }
  let mut i = 0
  let mut neg = false
  if t[0] == '-' {
    neg = true
    i = 1
  } else if t[0] == '+' {
    i = 1
  }
  let mut int_part : Int64 = 0L
  let mut any = false
  while i < t.length() {
    let dg = digit_of(t[i])
    if dg < 0 {
      break
    }
    int_part = int_part * 10L + dg.to_int64()
    any = true
    i = i + 1
  }
  let mut value = int_part.to_double()
  if i < t.length() && t[i] == '.' {
    i = i + 1
    let mut scale = 0.1
    while i < t.length() {
      let dg = digit_of(t[i])
      if dg < 0 {
        break
      }
      value = value + dg.to_double() * scale
      scale = scale / 10.0
      any = true
      i = i + 1
    }
  }
  if !any || i != t.length() {
    return None
  }
  if neg {
    Some(-value)
  } else {
    Some(value)
  }
}

// ---------------------------------------------------------------------------
// 格式化
//
// 不用 Double::to_string（它会给出 0.9000000000000001 这类尾巴，
// 而且某些值会走科学计数法），自己按位数四舍五入。
// 注意 Int 只有 32 位，所以缩放用 Int64。
// ---------------------------------------------------------------------------

///|
/// 定点小数格式化，四舍五入到 `digits` 位。
fn fmt_float(x : Double, digits : Int32) -> String {
  let neg = x < 0.0
  let v = if neg { -x } else { x }
  let mut scale : Int64 = 1L
  let mut i = 0
  while i < digits {
    scale = scale * 10L
    i = i + 1
  }
  let rounded = @math.floor(v * scale.to_double() + 0.5).to_int64()
  let ip = rounded / scale
  let fp = rounded % scale
  let body = if digits == 0 {
    ip.to_string()
  } else {
    let fs = fp.to_string()
    let sb = StringBuilder()
    sb.write_string(ip.to_string())
    sb.write_string(".")
    let mut pad = 0
    while pad < digits - fs.length() {
      sb.write_string("0")
      pad = pad + 1
    }
    sb.write_string(fs)
    sb.to_string()
  }
  if neg {
    "-" + body
  } else {
    body
  }
}

///|
/// 百分比格式化（0.9123 → "91.23%"）。
fn fmt_pct(x : Double) -> String {
  fmt_float(x * 100.0, 2) + "%"
}

///|
/// 左对齐、右侧补空格到 `width`。
fn pad_right(s : String, width : Int32) -> String {
  let sb = StringBuilder()
  sb.write_string(s)
  let mut n = width - s.length()
  while n > 0 {
    sb.write_string(" ")
    n = n - 1
  }
  sb.to_string()
}

///|
/// 右对齐、左侧补空格到 `width`。
fn pad_left(s : String, width : Int32) -> String {
  let sb = StringBuilder()
  let mut n = width - s.length()
  while n > 0 {
    sb.write_string(" ")
    n = n - 1
  }
  sb.write_string(s)
  sb.to_string()
}

///|
/// 横向分隔线。
fn hr(width : Int32) -> String {
  let sb = StringBuilder()
  let mut i = 0
  while i < width {
    sb.write_string("-")
    i = i + 1
  }
  sb.to_string()
}

///|
/// 简易条形图（用 # 表示），用于积压趋势。
fn bar(value : Double, max_value : Double, width : Int32) -> String {
  let cells = if max_value <= 0.0 {
    0
  } else {
    (value / max_value * width.to_double()).to_int()
  }
  let n = if cells < 0 { 0 } else if cells > width { width } else { cells }
  let sb = StringBuilder()
  let mut i = 0
  while i < n {
    sb.write_string("#")
    i = i + 1
  }
  sb.to_string()
}

// ---------------------------------------------------------------------------
// 用法文本
// ---------------------------------------------------------------------------

///|
/// 用法说明。数组拼装，因为 MoonBit 没有多行字符串。
fn usage_text() -> String {
  let lines = [
    "recall - 间隔重复调度引擎 (SM-2 / FSRS-5 / Leitner)", "", "用法:",
    "  recall replay   --log FILE --scheduler sm2|fsrs|leitner [--json]", "  recall compare  --log FILE --a sm2 --b fsrs",
    "  recall simulate --scheduler fsrs [--days 90] [--new-per-day 20]", "                  [--review-limit 200] [--policy realistic] [--seed N]",
    "  recall stats    --log FILE", "  recall curve    --log FILE [--buckets 10]",
    "", "选项:", "  --log            复习日志路径 (JSONL, 每行一个事件)",
    "  --scheduler      调度器: sm2 | fsrs | leitner", "  --a / --b        compare 的左右两侧调度器",
    "  --days           模拟天数 (默认 90)", "  --new-per-day    每天新增卡片数 (默认 20)",
    "  --review-limit   每天复习上限, 0 表示不限 (默认 200)", "  --policy         评分策略: optimistic | realistic | pessimistic (默认 realistic)",
    "  --buckets        保持率曲线分桶数 (默认 10)", "  --retention      目标保持率 (默认 0.9)",
    "  --seed           模拟的伪随机种子 (默认 20240101)", "  --json           以 JSON 输出 (仅 replay)",
    "", "退出码: 0 成功 / 1 数据错误 / 2 用法错误", "",
  ]
  let sb = StringBuilder()
  for line in lines {
    sb.write_string(line)
    sb.write_string("\n")
  }
  sb.to_string()
}

// ---------------------------------------------------------------------------
// 日志读取
// ---------------------------------------------------------------------------

///|
/// 读文本文件，失败返回 None（不抛）。
fn read_text(path : String) -> String? {
  let r = Some(@fs.read_file_to_string(path)) catch { _ => None }
  r
}

///|
/// 加载并解析日志。任何失败都打印原因并返回 None（调用方转成退出码 1）。
fn load_log(path : String) -> @lib.ReviewLog? {
  match read_text(path) {
    None => {
      println("数据错误: 无法读取文件 " + path)
      None
    }
    Some(text) => {
      let parsed = Some(@lib.ReviewLog::from_jsonl(text)) catch {
        @lib.BadLine(ln, why) => {
          println(
            "数据错误: 第 " +
            ln.to_string() +
            " 行解析失败 — " +
            why,
          )
          None
        }
        @lib.BadTimestamp(ln, raw) => {
          println(
            "数据错误: 第 " +
            ln.to_string() +
            " 行时间戳非法 — " +
            raw,
          )
          None
        }
        _ => {
          println("数据错误: JSONL 解析失败")
          None
        }
      }
      match parsed {
        None => None
        Some(result) =>
          match result {
            Ok(log) => Some(log)
            // Err 分支必须打印原因：core 的 from_jsonl 把错误包在 Result 里，
            // 不 raise 也不打印，静默返回 None 会让用户只看到退出码 1。
            Err(@lib.BadLine(ln, why)) => {
              println(
                "数据错误: 第 " +
                ln.to_string() +
                " 行解析失败 — " +
                why,
              )
              None
            }
            Err(@lib.BadTimestamp(ln, raw)) => {
              println(
                "数据错误: 第 " +
                ln.to_string() +
                " 行时间戳非法 — " +
                raw,
              )
              None
            }
          }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// 子命令：replay
// ---------------------------------------------------------------------------

///|
fn cmd_replay(args : Args) -> Int32 {
  let path = args.get("log", "")
  if path.length() == 0 {
    println("用法错误: replay 需要 --log FILE")
    return 2
  }
  let sched_name = args.get("scheduler", "fsrs")
  if !@lib.scheduler_name_valid(sched_name) {
    println(
      "用法错误: 未知调度器 " +
      sched_name +
      "（可选 sm2 / fsrs / leitner）",
    )
    return 2
  }
  let log = match load_log(path) {
    Some(v) => v
    None => return 1
  }
  let s = @lib.AnyScheduler::by_name(sched_name)
  let res = @lib.replay(log, s)
  if args.has("json") {
    let ids : Array[String] = []
    for cid in res.final_states.keys() {
      ids.push(cid)
    }
    ids.sort()
    let sb = StringBuilder()
    sb.write_string("{\"scheduler\":\"")
    sb.write_string(s.name())
    sb.write_string("\",\"cards\":")
    sb.write_string(res.final_states.length().to_string())
    sb.write_string(",\"total_reviews\":")
    sb.write_string(res.total_reviews.to_string())
    sb.write_string(",\"total_lapses\":")
    sb.write_string(res.total_lapses.to_string())
    sb.write_string(",\"interval_error_days\":")
    sb.write_string(fmt_float(res.interval_error_days, 4))
    sb.write_string(",\"final_intervals\":{")
    let mut first = true
    for cid in ids {
      let iv = match res.final_states.get(cid) {
        Some(st) => st.interval_days
        None => 0.0
      }
      if !first {
        sb.write_string(",")
      }
      first = false
      // R2 修复：card_id 直接拼接会产生非法 JSON —— id 含引号（a"b）时
      // 输出 {"a"b":1.00}。用 core 的 Json::string 做正确转义，它产出的
      // 字符串自带引号，直接作为键写入。
      sb.write_string(Json::string(cid).stringify())
      sb.write_string(":")
      sb.write_string(fmt_float(iv, 2))
    }
    sb.write_string("}}")
    println(sb.to_string())
  } else {
    println("调度器: " + s.name())
    println(
      "日志:   " + path + " (" + log.length().to_string() + " 个事件)",
    )
    println("卡片:   " + res.final_states.length().to_string() + " 张")
    println("复习:   " + res.total_reviews.to_string() + " 次")
    println("遗忘:   " + res.total_lapses.to_string() + " 次")
    println(
      "平均间隔偏差: " + fmt_float(res.interval_error_days, 2) + " 天",
    )
    println("")
    println(
      pad_right("卡片", 12) +
      pad_left("间隔(天)", 12) +
      pad_left("稳定性", 12) +
      pad_left(
        if sched_name == "sm2" {
          "EF"
        } else if sched_name == "leitner" {
          "盒号"
        } else {
          "难度"
        },
        9,
      ) +
      pad_left("复习", 7) +
      pad_left("遗忘", 7) +
      "  阶段",
    )
    println(hr(72))
    let ids : Array[String] = []
    for cid in res.final_states.keys() {
      ids.push(cid)
    }
    ids.sort()
    for cid in ids {
      let st = match res.final_states.get(cid) {
        Some(v) => v
        None => continue
      }
      println(
        pad_right(cid, 12) +
        pad_left(fmt_float(st.interval_days, 2), 12) +
        pad_left(fmt_float(st.stability, 2), 12) +
        pad_left(fmt_float(st.difficulty, 2), 9) +
        pad_left(st.reps.to_string(), 7) +
        pad_left(st.lapses.to_string(), 7) +
        "  " +
        st.phase.label(),
      )
    }
  }
  0
}

// ---------------------------------------------------------------------------
// 子命令：compare
// ---------------------------------------------------------------------------

///|
fn cmd_compare(args : Args) -> Int32 {
  let path = args.get("log", "")
  if path.length() == 0 {
    println("用法错误: compare 需要 --log FILE")
    return 2
  }
  let a_name = args.get("a", "sm2")
  let b_name = args.get("b", "fsrs")
  if !@lib.scheduler_name_valid(a_name) {
    println("用法错误: 未知调度器 --a " + a_name)
    return 2
  }
  if !@lib.scheduler_name_valid(b_name) {
    println("用法错误: 未知调度器 --b " + b_name)
    return 2
  }
  let log = match load_log(path) {
    Some(v) => v
    None => return 1
  }
  let a = @lib.AnyScheduler::by_name(a_name)
  let b = @lib.AnyScheduler::by_name(b_name)
  let c = @lib.compare(log, a, b)
  println("对比: " + c.a_name + "  vs  " + c.b_name)
  println(
    "日志: " +
    path +
    "  (" +
    log.length().to_string() +
    " 事件 / " +
    c.per_card.length().to_string() +
    " 卡片)",
  )
  println("")
  println(
    pad_right("指标", 22) +
    " " +
    pad_left(c.a_name, 14) +
    " " +
    pad_left(c.b_name, 14) +
    " " +
    pad_left("差值", 14),
  )
  println(hr(68))
  println(
    pad_right("最终间隔总和(天)", 22) +
    " " +
    pad_left(fmt_float(c.a_total_interval, 1), 14) +
    " " +
    pad_left(fmt_float(c.b_total_interval, 1), 14) +
    " " +
    pad_left(fmt_float(c.b_total_interval - c.a_total_interval, 1), 14),
  )
  println(
    pad_right("遗忘次数", 22) +
    " " +
    pad_left(c.a_lapses.to_string(), 14) +
    " " +
    pad_left(c.b_lapses.to_string(), 14) +
    " " +
    pad_left((c.b_lapses - c.a_lapses).to_string(), 14),
  )
  let n = c.per_card.length()
  let a_avg = if n == 0 { 0.0 } else { c.a_total_interval / n.to_double() }
  let b_avg = if n == 0 { 0.0 } else { c.b_total_interval / n.to_double() }
  println(
    pad_right("平均间隔(天)", 22) +
    " " +
    pad_left(fmt_float(a_avg, 1), 14) +
    " " +
    pad_left(fmt_float(b_avg, 1), 14) +
    " " +
    pad_left(fmt_float(b_avg - a_avg, 1), 14),
  )
  // 「触及间隔上限」的卡数：这是判断指标是否可比的**前提**。
  // interval_days 一旦顶到 max_interval_days()（100 年），说明该算法认为
  // 这张卡 100 年后才需要复习 —— 在真实场景里等价于「永远不再复习」。
  // 这类卡会把 total_interval 拉到失真的量级，导致「间隔总和越大越好」的
  // 直觉彻底失效（SM-2 就常常这样失控，而 FSRS 不会）。
  let cap = @lib.max_interval_days()
  let mut a_at_cap = 0
  let mut b_at_cap = 0
  for row in c.per_card {
    if row.1 >= cap {
      a_at_cap = a_at_cap + 1
    }
    if row.2 >= cap {
      b_at_cap = b_at_cap + 1
    }
  }
  println(
    pad_right("触及上限(100年)卡数", 22) +
    " " +
    pad_left(a_at_cap.to_string(), 14) +
    " " +
    pad_left(b_at_cap.to_string(), 14) +
    " " +
    pad_left((b_at_cap - a_at_cap).to_string(), 14),
  )
  println("")
  println("逐卡对比")
  println(
    pad_right("卡片", 14) +
    " " +
    pad_left(c.a_name, 14) +
    " " +
    pad_left(c.b_name, 14) +
    " " +
    pad_left("差值", 14),
  )
  println(hr(60))
  for row in c.per_card {
    println(
      pad_right(row.0, 14) +
      " " +
      pad_left(fmt_float(row.1, 1), 14) +
      " " +
      pad_left(fmt_float(row.2, 1), 14) +
      " " +
      pad_left(fmt_float(row.2 - row.1, 1), 14),
    )
  }
  let ratio = if c.a_total_interval > 0.0 {
    c.b_total_interval / c.a_total_interval
  } else {
    1.0
  }
  if n > 0 && c.a_total_interval > 0.0 {
    println("")
    println(
      "→ " +
      c.b_name +
      " 的最终间隔是 " +
      c.a_name +
      " 的 " +
      fmt_float(ratio, 2) +
      " 倍",
    )
  }
  // --- 解读提示：只在"有卡顶到上限"或"比值极端"时才出现 ---
  // 目的不是评判算法，而是阻止"间隔总和越大 = 算法越好"这个错误推断。
  let a_capped = a_at_cap > 0
  let b_capped = b_at_cap > 0
  if a_capped || b_capped {
    println("")
    println("⚠ 指标解读")
    if a_capped {
      println(
        "  " +
        c.a_name +
        " 有 " +
        a_at_cap.to_string() +
        "/" +
        n.to_string() +
        " 张卡触及 100 年上限：该算法认为它们 100 年后才需复习，",
      )
      println(
        "  在真实场景中等价于「永远不再复习」。这些卡把间隔总和拉得很大，",
      )
      println(
        "  因此「间隔总和/平均间隔」在此**不能**直接当作优劣比较。",
      )
    }
    if b_capped {
      println(
        "  " +
        c.b_name +
        " 有 " +
        b_at_cap.to_string() +
        "/" +
        n.to_string() +
        " 张卡触及 100 年上限，同样不可直接比较。",
      )
    }
    println(
      "  更可比的指标是「触及上限卡数」（越少越好）与「遗忘次数」。",
    )
  } else if ratio > 10.0 || ratio < 0.1 {
    println("")
    println(
      "⚠ 两侧间隔相差超过 10 倍，总量指标可能被少数极端卡主导，",
    )
    println("  建议结合逐卡对比与遗忘次数一起看。")
  }
  0
}

// ---------------------------------------------------------------------------
// 子命令：simulate
// ---------------------------------------------------------------------------

///|
fn cmd_simulate(args : Args) -> Int32 {
  let sched_name = args.get("scheduler", "fsrs")
  if !@lib.scheduler_name_valid(sched_name) {
    println("用法错误: 未知调度器 " + sched_name)
    return 2
  }
  let policy = args.get("policy", "realistic")
  if !@lib.grade_policy_valid(policy) {
    println(
      "用法错误: 未知评分策略 " +
      policy +
      "（可选 optimistic / realistic / pessimistic）",
    )
    return 2
  }
  // 数值参数区分「未提供」（用默认）与「提供了但不是数字」（用法错误）。
  // 旧实现把 --days abc 静默当作 90 天跑完并 exit 0——用户以为模拟的是
  // 自己要的时间窗口，实际不是。
  let days = match args.get_opt("days") {
    None => 90
    Some(v) =>
      match parse_int_loose(v) {
        Some(n) => n
        None => {
          println("用法错误: --days 需要一个整数，得到 '\{v}'")
          return 2
        }
      }
  }
  let new_per_day = match args.get_opt("new-per-day") {
    None => 20
    Some(v) =>
      match parse_int_loose(v) {
        Some(n) => n
        None => {
          println(
            "用法错误: --new-per-day 需要一个整数，得到 '\{v}'",
          )
          return 2
        }
      }
  }
  let review_limit = match args.get_opt("review-limit") {
    None => 200
    Some(v) =>
      match parse_int_loose(v) {
        Some(n) => n
        None => {
          println(
            "用法错误: --review-limit 需要一个整数，得到 '\{v}'",
          )
          return 2
        }
      }
  }
  let target_retention = match args.get_opt("retention") {
    None => 0.9
    Some(v) =>
      match parse_double_loose(v) {
        Some(n) => n
        None => {
          println(
            "用法错误: --retention 需要一个小数，得到 '\{v}'",
          )
          return 2
        }
      }
  }
  let seed = match args.get_opt("seed") {
    None => 20240101L
    Some(v) =>
      match parse_int_loose(v) {
        Some(n) => n.to_int64()
        None => {
          println("用法错误: --seed 需要一个整数，得到 '\{v}'")
          return 2
        }
      }
  }
  if days < 0 {
    println("用法错误: --days 必须非负")
    return 2
  }
  if new_per_day < 0 {
    println("用法错误: --new-per-day 必须非负")
    return 2
  }
  if review_limit < 0 {
    println("用法错误: --review-limit 必须非负（0 表示不限）")
    return 2
  }
  let cfg : @lib.SimConfig = {
    days,
    new_per_day,
    review_limit,
    desired_retention: target_retention,
    grade_fn: @lib.grade_policy_with_seed(policy, seed),
    seed,
  }
  // R1 修复：retention 现在真正传给调度器。SM-2/Leitner 没有这个参数
  // （算法局限），此时如实告知而不是沉默地忽略。
  let s = @lib.AnyScheduler::by_name_with_retention(
    sched_name, target_retention,
  )
  if sched_name != "fsrs" && target_retention != 0.9 {
    println(
      "提示: " +
      sched_name +
      " 调度器没有目标保持率参数（算法局限），" +
      "--retention " +
      fmt_float(target_retention, 2) +
      " 未生效（仅 FSRS 支持）",
    )
  }
  let res = @lib.simulate(s, cfg)
  println("模拟: " + s.name() + " / " + policy + " 策略")
  println(
    "参数: " +
    days.to_string() +
    " 天, 每天新增 " +
    new_per_day.to_string() +
    " 张, 复习上限 " +
    (if review_limit == 0 { "不限" } else { review_limit.to_string() }) +
    ", 目标保持率 " +
    fmt_float(target_retention, 2) +
    ", 种子 " +
    seed.to_string(),
  )
  println("")
  println(
    pad_right("天", 8) +
    pad_left("新卡", 8) +
    pad_left("到期", 8) +
    pad_left("已复习", 9) +
    pad_left("记住", 8) +
    pad_left("积压", 8) +
    "  积压趋势",
  )
  println(hr(78))
  // 长模拟按步长抽样，避免 90 行刷屏；但首尾必出
  let step = if days <= 20 { 1 } else if days <= 45 { 3 } else { 7 }
  let max_b = if res.max_backlog == 0 { 1 } else { res.max_backlog }
  for d in res.days {
    let show = d.day == 0 || d.day == days - 1 || d.day % step == 0
    if show {
      println(
        pad_right("#" + (d.day + 1).to_string(), 8) +
        pad_left(d.new_cards.to_string(), 8) +
        pad_left(d.due_cards.to_string(), 8) +
        pad_left(d.reviewed.to_string(), 9) +
        pad_left(d.retained.to_string(), 8) +
        pad_left(d.backlog.to_string(), 8) +
        "  " +
        bar(d.backlog.to_double(), max_b.to_double(), 20),
      )
    }
  }
  println("")
  println("总复习次数: " + res.total_reviews.to_string())
  println("最大积压:   " + res.max_backlog.to_string() + " 张")
  println("最终积压:   " + res.final_backlog.to_string() + " 张")
  if res.final_backlog > 0 {
    println("")
    println(
      "→ " +
      days.to_string() +
      " 天后仍有 " +
      res.final_backlog.to_string() +
      " 张卡在排队等待复习",
    )
  }
  0
}

// ---------------------------------------------------------------------------
// 子命令：stats
// ---------------------------------------------------------------------------

///|
fn cmd_stats(args : Args) -> Int32 {
  let path = args.get("log", "")
  if path.length() == 0 {
    println("用法错误: stats 需要 --log FILE")
    return 2
  }
  let log = match load_log(path) {
    Some(v) => v
    None => return 1
  }
  let rows = @lib.compute_stats(log)
  let overall = @lib.overall_stats(rows)
  println("统计: " + path)
  println(
    "      " +
    log.length().to_string() +
    " 个事件 / " +
    overall.cards.to_string() +
    " 张卡片",
  )
  println("")
  println(
    pad_right("卡片", 14) +
    pad_left("复习", 8) +
    pad_left("遗忘", 8) +
    pad_left("均间隔", 10) +
    pad_left("最大间隔", 11) +
    pad_left("保持率", 10),
  )
  println(hr(61))
  for r in rows {
    println(
      pad_right(r.card_id, 14) +
      pad_left(r.reviews.to_string(), 8) +
      pad_left(r.lapses.to_string(), 8) +
      pad_left(fmt_float(r.mean_interval, 2), 10) +
      pad_left(fmt_float(r.max_interval, 2), 11) +
      pad_left(fmt_pct(r.retention_rate), 10),
    )
  }
  println(hr(61))
  println(
    pad_right("合计", 14) +
    pad_left(overall.reviews.to_string(), 8) +
    pad_left(overall.lapses.to_string(), 8) +
    pad_left(fmt_float(overall.mean_interval, 2), 10) +
    pad_left("", 11) +
    pad_left(fmt_pct(overall.retention_rate), 10),
  )
  0
}

// ---------------------------------------------------------------------------
// 子命令：curve
// ---------------------------------------------------------------------------

///|
fn cmd_curve(args : Args) -> Int32 {
  let path = args.get("log", "")
  if path.length() == 0 {
    println("用法错误: curve 需要 --log FILE")
    return 2
  }
  // 数值参数区分「未提供」（用默认）与「提供了但不是数字」（用法错误），
  // 与 --days / --new-per-day 等保持同一模式。
  // 旧实现经 get_int 把非法值静默回退成默认 10 并 exit 0——
  // 用户以为画的是自己要的桶数，实际不是。
  let buckets = match args.get_opt("buckets") {
    None => 10
    Some(v) =>
      match parse_int_loose(v) {
        Some(n) => n
        None => {
          println("用法错误: --buckets 需要一个整数，得到 '\{v}'")
          return 2
        }
      }
  }
  if buckets < 1 {
    println("用法错误: --buckets 必须 >= 1")
    return 2
  }
  let log = match load_log(path) {
    Some(v) => v
    None => return 1
  }
  let curve = @lib.retention_curve(log, buckets)
  println("保持率曲线: " + path + "（" + buckets.to_string() + " 桶）")
  println("")
  if curve.length() == 0 {
    // R5：空结果有两种原因，混在一句里会误导——「每卡只有一次复习」
    // 和「日志为空」是不同的问题。另外说明分桶语义：elapsed_days 恰好
    // 等于桶上界的样本会落入下一桶（floor 除法），边界归属有 ±1 桶宽
    // 的模糊，这是与 compute_stats（直接对事件算）数值不同的原因之一。
    println(
      "（保持率曲线为空：分桶需要同卡多次复习产生的正间隔样本；",
    )
    println(
      "  日志为空、每卡仅一次复习、或所有间隔都落在最后一个桶边界之后时结果为空）",
    )
    return 0
  }
  println(
    pad_right("间隔上界(天)", 16) + pad_left("保持率", 10) + "  曲线",
  )
  println(hr(62))
  for row in curve {
    let cells = (row.1 * 30.0).to_int()
    let sb = StringBuilder()
    let mut i = 0
    while i < cells {
      sb.write_string("#")
      i = i + 1
    }
    println(
      pad_right("< " + fmt_float(row.0, 1), 16) +
      pad_left(fmt_pct(row.1), 10) +
      "  " +
      sb.to_string(),
    )
  }
  // 单调性自检
  let mut prev = 2.0
  let mut monotone = true
  for row in curve {
    if row.1 > prev {
      monotone = false
    }
    prev = row.1
  }
  println("")
  if monotone {
    println("→ 曲线单调不增，符合遗忘规律")
  } else {
    println("→ 曲线出现回升（样本噪声，或分桶过细）")
  }
  0
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

///|
fn usage_error(msg : String) -> Unit {
  println("用法错误: " + msg)
  println("")
  println(usage_text())
}

///|
fn main {
  let argv = @env.args()
  // argv[0] 是程序自身，跳过
  let rest : Array[String] = []
  let mut i = 1
  while i < argv.length() {
    rest.push(argv[i])
    i = i + 1
  }
  if rest.length() == 0 {
    println(usage_text())
    @sys.exit(2)
  }
  let sub = rest[0]
  let tail : Array[String] = []
  let mut j = 1
  while j < rest.length() {
    tail.push(rest[j])
    j = j + 1
  }
  let args = parse_args(tail)
  let code = match sub {
    "replay" => cmd_replay(args)
    "compare" => cmd_compare(args)
    "simulate" => cmd_simulate(args)
    "stats" => cmd_stats(args)
    "curve" => cmd_curve(args)
    "help" => {
      println(usage_text())
      0
    }
    "--help" => {
      println(usage_text())
      0
    }
    "-h" => {
      println(usage_text())
      0
    }
    _ => {
      usage_error("未知子命令 " + sub)
      2
    }
  }
  if code != 0 {
    @sys.exit(code)
  }
}
