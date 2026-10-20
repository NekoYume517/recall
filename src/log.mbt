// recall — 复习日志与 JSONL 序列化
//
// 合同：API.md 第 2 节。
//
// 核心设计：**日志是唯一真相来源**。不存冗余的卡片状态，任何状态都由
// 重放日志得到。因此这里的读写必须严格无损——一行错位就会让整条历史失效。
//
// JSONL 每行格式（字段名固定，顺序也固定，保证往返字节一致）：
//   {"card_id":"c1","reviewed_at":1700000000,"due_at":1699999000,"grade":3,"elapsed_days":1}

///|
/// 一次复习事件。
pub(all) struct ReviewEvent {
  card_id : String
  reviewed_at : Timestamp // 实际复习时刻
  due_at : Timestamp // 当时系统认为的到期时间（用于计算 overdue）
  grade : Grade
  elapsed_days : Double // 距上次复习的天数；首次为 0
} derive(Debug)

///|
/// 有序事件集合。保持插入顺序（文件里的行序）。
pub(all) struct ReviewLog {
  events : Array[ReviewEvent]
} derive(Debug)

///|
/// 日志读写错误。带行号，方便用户直接定位文件问题。
pub(all) suberror LogError {
  BadLine(Int32, String)
  BadTimestamp(Int32, String)
} derive(Debug)

///|
/// `elapsed_days` 的 JSON 字段名。
fn key_card_id() -> String {
  "card_id"
}

///|
/// 时间戳字段名。
fn key_reviewed_at() -> String {
  "reviewed_at"
}

///|
/// 到期时间字段名。
fn key_due_at() -> String {
  "due_at"
}

///|
/// 评分字段名。
fn key_grade() -> String {
  "grade"
}

///|
/// 间隔天数字段名。
fn key_elapsed_days() -> String {
  "elapsed_days"
}

///|
/// 构造事件（顺手把 elapsed 夹到非负，负数在物理上无意义）。
pub fn ReviewEvent::new(
  card_id : String,
  reviewed_at : Timestamp,
  due_at : Timestamp,
  grade : Grade,
  elapsed_days : Double,
) -> ReviewEvent {
  let e = if elapsed_days < 0.0 { 0.0 } else { elapsed_days }
  { card_id, reviewed_at, due_at, grade, elapsed_days: e, }
}

///|
/// 逾期天数：实际复习时刻晚于计划到期时刻多少天（提前复习返回 0）。
pub fn ReviewEvent::overdue_days(self : ReviewEvent) -> Double {
  let d = days_between(self.due_at, self.reviewed_at)
  if d > 0.0 {
    d
  } else {
    0.0
  }
}

///|
/// 事件相等（只 derive(Debug)，手写比较）。
pub fn ReviewEvent::equal(a : ReviewEvent, b : ReviewEvent) -> Bool {
  a.card_id == b.card_id &&
  a.reviewed_at == b.reviewed_at &&
  a.due_at == b.due_at &&
  a.grade == b.grade &&
  a.elapsed_days == b.elapsed_days
}

///|
/// 空日志。
pub fn ReviewLog::new() -> ReviewLog {
  { events: [], }
}

///|
/// 追加一个事件（保持顺序）。
pub fn ReviewLog::push(self : ReviewLog, ev : ReviewEvent) -> Unit {
  self.events.push(ev)
}

///|
/// 事件条数。
pub fn ReviewLog::length(self : ReviewLog) -> Int32 {
  self.events.length()
}

///|
/// 是否为空。
pub fn ReviewLog::is_empty(self : ReviewLog) -> Bool {
  self.events.length() == 0
}

///|
/// 按 card_id 分组，**每组内部按 `reviewed_at` 升序**（稳定排序：
/// 同一秒的多次复习保持文件里的先后顺序）。
///
/// 返回的 Map 保留卡片首次出现的顺序（底层是 LinkedHashMap），
/// 这样 CLI 输出不会因为哈希顺序而抖动。
pub fn ReviewLog::by_card(self : ReviewLog) -> Map[String, Array[ReviewEvent]] {
  let groups : Map[String, Array[ReviewEvent]] = Map([])
  for ev in self.events {
    let bucket = groups.get_or_init(ev.card_id, fn() { [] })
    bucket.push(ev)
  }
  for key, bucket in groups {
    // 稳定排序：比较 reviewed_at，相等时返回 -1 以保住原顺序。
    let indexed : Array[(Int32, ReviewEvent)] = []
    for i, ev in bucket {
      indexed.push((i, ev))
    }
    indexed.sort_by(fn(a, b) {
      let d = a.1.reviewed_at - b.1.reviewed_at
      if d < 0L {
        -1
      } else if d > 0L {
        1
      } else {
        a.0 - b.0
      }
    })
    for i, pair in indexed {
      bucket[i] = pair.1
    }
    ignore(key)
  }
  groups
}

///|
/// 全部卡片 id（首次出现顺序，去重）。
pub fn ReviewLog::card_ids(self : ReviewLog) -> Array[String] {
  let seen : Map[String, Bool] = Map([])
  let out : Array[String] = []
  for ev in self.events {
    match seen.get(ev.card_id) {
      Some(_) => ()
      None => {
        seen[ev.card_id] = true
        out.push(ev.card_id)
      }
    }
  }
  out
}

///|
/// 单条事件 → JSON 对象。字段顺序即输出顺序。
fn event_to_json(ev : ReviewEvent) -> Json {
  let m : Map[String, Json] = Map([])
  m[key_card_id()] = Json::string(ev.card_id)
  m[key_reviewed_at()] = Json::number(ev.reviewed_at.to_double())
  m[key_due_at()] = Json::number(ev.due_at.to_double())
  m[key_grade()] = Json::number(ev.grade.to_int().to_double())
  m[key_elapsed_days()] = Json::number(ev.elapsed_days)
  Json::object(m)
}

///|
/// 序列化成 JSONL。每行一个事件，行尾带 `\n`（含最后一行）。
///
/// 用 core/json 构造而非手拼字符串：`card_id` 里若含引号、反斜杠、
/// 换行或非 ASCII 字符，只有走 stringify 的转义才是正确的。
pub fn ReviewLog::to_jsonl(self : ReviewLog) -> String {
  let sb = StringBuilder()
  for ev in self.events {
    sb.write_string(event_to_json(ev).stringify())
    sb.write_char('\n')
  }
  sb.to_string()
}

///|
/// 从 JSON 值里取字符串字段。缺失或类型不符都算坏行。
fn field_string(
  obj : Map[String, Json],
  key : String,
  line_no : Int32,
) -> String raise LogError {
  match obj.get(key) {
    Some(String(s)) => s
    Some(_) => raise BadLine(line_no, "字段 \{key} 不是字符串")
    None => raise BadLine(line_no, "缺少字段 \{key}")
  }
}

///|
/// 从 JSON 值里取整数（时间戳）。JSON 数字是 Double，
/// 因此这里检查范围并四舍五入到秒。
fn field_timestamp(
  obj : Map[String, Json],
  key : String,
  line_no : Int32,
) -> Timestamp raise LogError {
  match obj.get(key) {
    Some(Number(n, ..)) => {
      let ok = !n.is_nan() && n >= -62135596800.0 && n <= 253402300799.0
      if !ok {
        raise BadTimestamp(line_no, key)
      }
      @math.round(n).to_int64()
    }
    Some(String(_)) => raise BadTimestamp(line_no, key)
    Some(_) => raise BadTimestamp(line_no, key)
    None => raise BadLine(line_no, "缺少字段 \{key}")
  }
}

///|
/// 从 JSON 值里取浮点字段（`elapsed_days`）。
///
/// 校验有限性：Infinity / NaN 的 `elapsed_days` 会让下游归桶溢出、保持率上界
/// 打印成异常大值，必须拒绝而不是静默进入统计。（`grade` 的非整数由调用方
/// 经 `Grade::from_int` 归一化，属于特性；这里只管 `elapsed_days` 的有限性。）
fn field_double(
  obj : Map[String, Json],
  key : String,
  line_no : Int32,
) -> Double raise LogError {
  match obj.get(key) {
    Some(Number(n, ..)) =>
      // 有限性校验：NaN 的 is_nan 为 true；Infinity 的 (n-n) 为 NaN。
      // 两者都判为非有限值拒绝，避免下游归桶时 Infinity 溢出、上界打印异常大值。
      if n.is_nan() || (n - n).is_nan() {
        raise BadLine(line_no, "字段 \{key} 必须是有限数字，得到非有限值")
      } else {
        n
      }
    Some(_) => raise BadLine(line_no, "字段 \{key} 不是数字")
    None => raise BadLine(line_no, "缺少字段 \{key}")
  }
}

///|
/// 单行 → 事件。所有错误都带上行号。
fn event_from_line(
  line : StringView,
  line_no : Int32,
) -> ReviewEvent raise LogError {
  let parsed : Json = @json.parse(line) catch {
    _ => raise BadLine(line_no, "不是合法 JSON")
  }
  let obj = match parsed {
    Object(m) => m
    _ => raise BadLine(line_no, "顶层不是 JSON 对象")
  }
  let card_id = field_string(obj, key_card_id(), line_no)
  let reviewed_at = field_timestamp(obj, key_reviewed_at(), line_no)
  let due_at = field_timestamp(obj, key_due_at(), line_no)
  let grade_num = field_double(obj, key_grade(), line_no)
  let elapsed = field_double(obj, key_elapsed_days(), line_no)
  let grade = Grade::from_int(@math.round(grade_num).to_int())
  ReviewEvent::new(card_id, reviewed_at, due_at, grade, elapsed)
}

///|
/// 从 JSONL 文本读入。
///
/// 行为约定：
/// - 空行（含只有空白字符的行）跳过，但仍然**计入行号**
/// - 行号从 1 开始，指向原始文件里的实际行
/// - 任一坏行立即返回 `Err`，不做部分成功（重放需要完整历史）
pub fn ReviewLog::from_jsonl(
  text : StringView,
) -> Result[ReviewLog, LogError] raise {
  let log = ReviewLog::new()
  let lines = text.split("\n").collect()
  for i, raw in lines {
    let line_no = i + 1
    let trimmed = raw.trim()
    if trimmed == "" {
      continue
    }
    // UTF-8 BOM：Windows 记事本、PowerShell `>` 重定向等工具会在文件头
    // 写入 U+FEFF。它不属于 JSON，却会让第一行的 `@json.parse` 失败，
    // 整份合法日志被当成数据错误拒收。只剥首行行首的一个 BOM。
    let cleaned : StringView = if i == 0 && trimmed.has_prefix("﻿") {
      // 去掉 BOM（UTF-16 下的单个码元 U+FEFF），切片不复制
      trimmed[1:trimmed.length()]
    } else {
      trimmed
    }
    let ev = event_from_line(cleaned, line_no) catch { e => return Err(e) }
    log.push(ev)
  }
  Ok(log)
}

///|
/// 两个日志是否逐事件相等（往返测试用）。
pub fn ReviewLog::equal(a : ReviewLog, b : ReviewLog) -> Bool {
  if a.events.length() != b.events.length() {
    return false
  }
  for i, ev in a.events {
    if !ReviewEvent::equal(ev, b.events[i]) {
      return false
    }
  }
  true
}
