// recall — Anki 可读格式导出
//
// 合同：PLAN.md 后续路线第 3 项（tags 字段预留的兑现）。
//
// 产出 **Anki 文本导入格式**（TSV + 指令头），不是 .apkg 二进制——
// .apkg 是 SQLite + zip 的私有打包，Anki 官方明确支持从纯文本导入
// （File > Import），TSV 是文档化的公开格式，不依赖 Anki 版本内部实现。
//
// 格式（Anki 23.10+ 文本导入规范）：
//
//   #separator:tab
//   #html:false
//   #columns:<以 Tab 分隔的八个列名，与数据行使用同一分隔符>
//   <card_id>\t<S>\t<D>\t<reps>\t<lapses>\t<due ISO8601>\t<interval>\t<phase>
//
// 每行一张卡的**最终状态**（重放日志得到），字段顺序固定，
// 方便人工核对与 diff。时间用 ISO8601（Anki 显示友好）；
// `#columns` 头让 Anki 导入向导自动识别列含义。

// ---------------------------------------------------------------------------
// 时间格式化
// ---------------------------------------------------------------------------

///|
/// Unix 秒时间戳 → ISO8601（UTC，"YYYY-MM-DD HH:MM:SS"）。
///
/// 纯手写历法换算（ civil_from_days 算法，Howard Hinnant 版本），
/// 不引入任何日期库。正确性由 roundtrip 测试锚定若干已知日期。
pub fn timestamp_to_iso8601(ts : Timestamp) -> String {
  // ⚠️ 负时间戳必须向负无穷取整（floor），不能用 MoonBit 默认的
  // 向零截断：1900-02-28 00:00:00 UTC = -2203958400 秒，/86400 向零
  // 截断会得到"第 -2550 天 + 负余秒"，分钟/秒变成负数（实测输出
  // "-18:-40:00"）。floor 之后才是"第 -2551 天的 00:00:00"。
  let raw_days = ts / 86400L
  let rem = ts % 86400L
  let days = (if rem < 0L { raw_days - 1L } else { raw_days }).to_int() // floor
  let secs_of_day = if rem < 0L { rem + 86400L } else { rem }
  // civil_from_days：天数 → (y, m, d)
  let z = days + 719468
  let era = (if z >= 0 { z } else { z - 146096 }) / 146097
  let doe = z - era * 146097 // [0, 146096]
  let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365 // [0, 399]
  let y = yoe + era * 400
  let doy = doe - (365 * yoe + yoe / 4 - yoe / 100) // [0, 365]
  let mp = (5 * doy + 2) / 153 // [0, 11]
  let d = doy - (153 * mp + 2) / 5 + 1 // [1, 31]
  let m = if mp < 10 { mp + 3 } else { mp - 9 } // [1, 12]
  let year = if m <= 2 { y + 1 } else { y }
  let hh = secs_of_day / 3600L
  let mm = secs_of_day % 3600L / 60L
  let ss = secs_of_day % 60L
  let pad2 = fn(n : Int64) -> String {
    let s = n.to_string()
    if s.length() < 2 {
      "0" + s
    } else {
      s
    }
  }
  let ystr = if year < 0 { "-" + (-year).to_string() } else { year.to_string() }
  // 年份补 4 位（Anki 的 CSV 解析器期待 4 位年）
  let y4 = if ystr.length() < 4 {
    let zeros = 4 - ystr.length()
    let sb = StringBuilder()
    if year < 0 {
      sb.write_string("-")
      for i = 0; i < zeros; i = i + 1 {
        sb.write_char('0')
      }
      sb.write_string((-year).to_string())
    } else {
      for i = 0; i < zeros; i = i + 1 {
        sb.write_char('0')
      }
      sb.write_string(ystr)
    }
    sb.to_string()
  } else {
    ystr
  }
  "\{y4}-\{pad2(m.to_int64())}-\{pad2(d.to_int64())} \{pad2(hh)}:\{pad2(mm)}:\{pad2(ss)}"
}

// ---------------------------------------------------------------------------
// 导出主体
// ---------------------------------------------------------------------------

///|
/// 导出列名（与 Anki #columns 指令一致）。
fn anki_columns() -> Array[String] {
  [
    "card_id", "stability", "difficulty", "reps", "lapses", "due", "interval_days",
    "phase",
  ]
}

///|
/// Anki 文本导入使用 CSV 引号规则，即便分隔符为 Tab：字段包含
/// 分隔符、换行或引号时包双引号，内部双引号翻倍。
/// 行首 # 会被识别为注释，所以这类 ID 也必须引用。
fn anki_escape_field(s : String) -> String {
  let needs_quotes = s.has_prefix("#") ||
    s.contains("\t") ||
    s.contains("\r") ||
    s.contains("\n") ||
    s.contains("\"")
  if !needs_quotes {
    return s
  }
  let sb = StringBuilder()
  sb.write_char('"')
  for c in s.to_array() {
    if c == '"' {
      sb.write_char('"')
    }
    sb.write_char(c)
  }
  sb.write_char('"')
  sb.to_string()
}

///|
/// 单张卡状态 → 一行 TSV。
fn card_to_tsv_line(st : CardState, scheduler_name : String) -> String {
  // difficulty 语义按调度器分派（见 types.mbt 的说明），列头带调度器名
  // 防止跨算法误读——FSRS 的 D ∈ [1,10]，SM-2 是 EF（约 1.3..3），Leitner 是盒号
  let diff_note = match scheduler_name {
    "fsrs" => "\{st.difficulty}"
    "sm2" => "\{st.difficulty}"
    _ => "\{st.difficulty}"
  }
  [
    st.card_id,
    st.stability.to_string(),
    diff_note,
    st.reps.to_string(),
    st.lapses.to_string(),
    timestamp_to_iso8601(st.due),
    st.interval_days.to_string(),
    st.phase.label(),
  ]
  .map(anki_escape_field)
  .join("\t")
}

///|
fn anki_comment_value(s : String) -> String {
  let sb = StringBuilder()
  for c in s.to_array() {
    match c {
      '\r' => sb.write_string("\\r")
      '\n' => sb.write_string("\\n")
      _ => sb.write_char(c)
    }
  }
  sb.to_string()
}

///|
/// 重放最终状态 → Anki 文本导入格式（TSV + 指令头）。
///
/// 卡片按 card_id 字典序排列——稳定顺序让两次导出可逐字节比较，
/// 也让人工浏览有固定次序。
///
/// 调度器名放入普通注释，说明 difficulty 的语义（FSRS=D、SM-2=EF、
/// Leitner=盒号）。它不是用户的 Anki 笔记类型，不设置 notetype 指令。
pub fn export_anki_tsv(
  states : Array[CardState],
  scheduler_name : String,
) -> String {
  let sb = StringBuilder()
  sb.write_string("#separator:tab\n")
  sb.write_string("#html:false\n")
  sb.write_string("# scheduler: \{anki_comment_value(scheduler_name)}\n")
  sb.write_string("#columns:" + anki_columns().join("\t") + "\n")
  // 排序：card_id 字典序
  let sorted = states.copy()
  sorted.sort_by(fn(a, b) { a.card_id.compare(b.card_id) })
  for st in sorted {
    sb.write_string(card_to_tsv_line(st, scheduler_name))
    sb.write_string("\n")
  }
  sb.to_string()
}

///|
/// 从复习日志重放到最终状态再导出——一步到位的便捷入口。
///
/// 内部复用 replay 引擎：日志是唯一真相来源，导出绝不引入第二份
/// 状态逻辑。
pub fn export_anki_from_log(log : ReviewLog, s : AnyScheduler) -> String {
  let res = replay(log, s)
  let states : Array[CardState] = []
  for cid in res.final_states.keys() {
    match res.final_states.get(cid) {
      Some(st) => states.push(st)
      None => ()
    }
  }
  export_anki_tsv(states, s.name())
}
