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
/// **年份宽度**：不足 4 位补零到 4 位（如 `0001-01-01`），恰好 4 位原样，
/// **超过 4 位原样输出、不截断**（如 `10099-12-06`、`292277026596-12-04`）。
/// `due` 可以合法地越过 9999 年（JSONL 的 reviewed_at 上限加
/// `max_interval_days()`），截断会把未来日期说成公元 99 年，因此保留完整
/// 年份。详见函数体内关于 RC-6 的说明。
///
/// **完整 Int64 域**（RJ-A1）：`ts` 取 Int64 全域都按 Hinnant 算法精确
/// 换算，不饱和、不回绕——`Int64.MAX` 给出 `292277026596-12-04 15:30:07`。
/// 正确性由 Python 版独立参考实现复算的边界向量锚定。
///
/// 纯手写历法换算（ civil_from_days 算法，Howard Hinnant 版本），
/// 不引入任何日期库。正确性由 roundtrip 测试锚定若干已知日期。
pub fn timestamp_to_iso8601(ts : Timestamp) -> String {
  // ⚠️ 负时间戳必须向负无穷取整（floor），不能用 MoonBit 默认的
  // 向零截断。例如 -1 秒应为 1969-12-31 23:59:59 UTC：
  // 向零除法给出第 0 天、余数 -1；floor 则是第 -1 天、日内 86399 秒。
  // 1900-02-28 00:00:00 UTC = -2203977600 秒，恰为整天，本身不触发此差异。
  //
  // ⚠️ 天数字段必须全程 Int64（RJ-A1，2026-11-10 审计）：旧实现把天数
  // `.to_int()` 压进 Int32，ts ≥ 185,542,587,187,200 秒（= 2^31 天）后
  // 静默回绕——Int64.MAX 曾被算成 1587287-03-17 15:30:07（真值
  // 292277026596-12-04 15:30:07），回绕产物还被测试与 API.md 当域事实
  // 锁死。`API.md` 承诺完整 Int64 时间戳解析，因此这里不放饱和/不报错，
  // 直接按 Int64 算到底：Hinnant 各中间量（era/doe/yoe）都远小于 2^31，
  // 只有 `days` / `y` / `year` 需要 Int64 承载。
  let raw_days = ts / 86400L
  let rem = ts % 86400L
  let days : Int64 = if rem < 0L { raw_days - 1L } else { raw_days } // floor
  let secs_of_day = if rem < 0L { rem + 86400L } else { rem }
  // civil_from_days：天数 → (y, m, d)。
  //
  // ⚠️ 除法必须显式 floor，不能依赖截断除法加经验修正（RJ-A1 第二层）：
  // Hinnant 原式的 `era = (z >= 0 ? z : z - 146096) / 146097` 依赖
  // 「`z - 146096` 与 z 同余」这个并不成立的前提（146096 = 146097 - 1，
  // 减它会把余数 +1），在极端负天数处 era 会偏 1 天——实测 Int64.MIN
  // 因此差一天（01-27 vs 真值 01-28）。这里改成显式 floor_div：
  // 负数先减 (b-1) 再截断，等价于数学 floor，全域正确。
  let floor_div = fn(a : Int64, b : Int64) -> Int64 {
    if a >= 0L {
      a / b
    } else {
      (a - (b - 1L)) / b
    }
  }
  let z = days + 719468L
  let era = floor_div(z, 146097L)
  let doe = z - era * 146097L // [0, 146096]
  let yoe = floor_div(doe - doe / 1460L + doe / 36524L - doe / 146096L, 365L) // [0, 399]
  let y = yoe + era * 400L
  let doy = doe - (365L * yoe + yoe / 4L - yoe / 100L) // [0, 365]
  let mp = (5L * doy + 2L) / 153L // [0, 11]
  let d = doy - (153L * mp + 2L) / 5L + 1L // [1, 31]
  let m = if mp < 10L { mp + 3L } else { mp - 9L } // [1, 12]
  let year = if m <= 2L { y + 1L } else { y }
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
  let ystr = if year < 0L {
    "-" + (-year).to_string()
  } else {
    year.to_string()
  }
  // 年份宽度规则（RC-6，2026-10-27 修正描述）：
  //   - 不足 4 位 → 补零到 4 位（0001 年写成 "0001"）
  //   - 恰好 4 位 → 原样
  //   - 超过 4 位 → **原样输出，不截断**
  //
  // 旧注释写的是「年份补 4 位（Anki 的 CSV 解析器期待 4 位年）」，
  // 但实现从来没做过"4 位"这个约束——超过 4 位时一直走 else 原样输出。
  // 那句注释把一条从未实现的规则说成契约，是文档谎言。
  //
  // 为什么保持不截断：`due` 可以合法地越过 9999 年——JSONL 允许的
  // reviewed_at 上限是 253402300799（9999-12-31 23:59:59），加上
  // max_interval_days() = 36500 天即 10099 年；完整 Int64 上限对应
  // 292277026596 年（RJ-A1 修正：旧注写 1587287 年，是 Int32 回绕的
  // 产物，不是域事实）。截断会把 10099 年写成 "0099"（把未来的到期日
  // 说成公元 99 年），比"多一位数字"更糟。因此保留现状并锁定测试。
  let y4 = if ystr.length() < 4 {
    let zeros = 4 - ystr.length()
    let sb = StringBuilder()
    if year < 0L {
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
    // 4 位与超 4 位都走这里：完整保留，不补也不截
    ystr
  }
  "\{y4}-\{pad2(m)}-\{pad2(d)} \{pad2(hh)}:\{pad2(mm)}:\{pad2(ss)}"
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
fn card_to_tsv_line(st : CardState) -> String {
  // difficulty 保留调度器原值；导出头部的 scheduler 注释说明其语义。
  [
    st.card_id,
    st.stability.to_string(),
    st.difficulty.to_string(),
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
  sorted.sort_by(fn(a, b) { a.card_id.lexical_compare(b.card_id) })
  for st in sorted {
    sb.write_string(card_to_tsv_line(st))
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
