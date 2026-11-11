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
#derive(Debug)
pub(all) struct ReviewEvent {
  card_id : String
  reviewed_at : Timestamp // 实际复习时刻
  due_at : Timestamp // 当时系统认为的到期时间（用于计算 overdue）
  grade : Grade
  elapsed_days : Double // 距上次复习的天数；首次为 0
  /// **原始评分整数**（RJ-R，2026-11-07 组委会验收意见）。
  ///
  /// Grade 是 4 档枚举，JSONL 的 grade 是 0..5 的 6 值刻度：
  /// 1|2 都归并为 Hard、4|5 都归并为 Easy。旧实现只存枚举，
  /// 写回时用代表值 2/5，于是原文 1 变 2、4 变 5 ——
  /// 申报承诺的「无损复习日志」在评分值上被证伪（组委会驳回意见）。
  ///
  /// 调度语义仍由 grade 枚举驱动（1 与 2 的调度行为相同，这是 FSRS/SM-2
  /// 的定义）；grade_raw 只为**日志保真**服务：from_jsonl 记录原文，
  /// to_jsonl 写回原文，ReviewLog::from_jsonl(to_jsonl(log)) 逐字节
  /// 恒等。非 JSONL 路径（
  /// new 构造）取 grade.to_int() 代表值 ——
  /// 那些调用点本来就没有「原文」可保。
  ///
  /// RJ-1b（2026-11-08 审计）：Int32 承载不了超域原文（2500000000 饱和成
  /// 2147483647，首次往返即非恒等），扩为 Int64 —— JSON 数字是 Double，
  /// Int64 无损承载到 2^53；超出精确整数域的输入由 from_jsonl 拒收。
  grade_raw : Int64
}

///|
/// 有序事件集合。保持插入顺序（文件里的行序）。
#derive(Debug)
pub(all) struct ReviewLog {
  events : Array[ReviewEvent]
}

///|
/// 日志读写错误。带行号，方便用户直接定位文件问题。
#derive(Debug)
pub(all) suberror LogError {
  BadLine(Int32, String)
  BadTimestamp(Int32, String)
}

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
  // 无「原文」可保的构造路径：grade_raw 取该档的代表值。
  // JSONL 解析走 new_with_raw，那里才记录用户的原始整数。
  {
    card_id,
    reviewed_at,
    due_at,
    grade,
    elapsed_days: e,
    grade_raw: grade.to_int().to_int64(),
  }
}

///|
/// 带原始评分整数的构造：**JSONL 解析专用**（RJ-R）。
///
/// grade 仍经 Grade::from_int 归一化供调度使用；grade_raw 保存
/// JSON 里的原始整数（0..5 及夹到两端的越界值），to_jsonl 原样写回。
/// 这是「无损日志」承诺的实现落点。
pub fn ReviewEvent::new_with_raw(
  card_id : String,
  reviewed_at : Timestamp,
  due_at : Timestamp,
  grade : Grade,
  grade_raw : Int64,
  elapsed_days : Double,
) -> ReviewEvent {
  let e = if elapsed_days < 0.0 { 0.0 } else { elapsed_days }
  { card_id, reviewed_at, due_at, grade, elapsed_days: e, grade_raw, }
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
///
/// 必须**逐字段**比较，包括 `grade_raw`（R-4，2026-11-11 审计）：`grade` 是
/// 夹取后的五档，`grade_raw` 是日志里的原始整数、也是「无损日志」这条承诺的
/// 载体（API.md §2）。修复前这里漏了 `grade_raw`，于是
/// `grade_raw` 1 与 2（都是 Hard）、4 与 5（都是 Easy）被判为相等 ——
/// 用 `ReviewLog::equal` 校验日志同一性的调用方会漏掉一整类差异，
/// 而这正是 RJ-R / RJ-1b 当年修的那类保真缺陷。
pub fn ReviewEvent::equal(a : ReviewEvent, b : ReviewEvent) -> Bool {
  a.card_id == b.card_id &&
  a.reviewed_at == b.reviewed_at &&
  a.due_at == b.due_at &&
  a.grade == b.grade &&
  a.grade_raw == b.grade_raw &&
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
      // RJ-2（2026-11-08 审计）：不做减法 —— Int64 极值相减回绕
      // （MAX - MIN = -1）会让排序翻转，这是 N-1（days_between，
      // dcbdd7b）修复时漏掉的同源比较器。直接比较无回绕。
      let ta = a.1.reviewed_at
      let tb = b.1.reviewed_at
      if ta < tb {
        -1
      } else if ta > tb {
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
  // **无损写回**（RJ-R）：写原始评分整数而不是枚举代表值 —— 原文 1/4
  // 不再变成 2/5。grade_raw 由 from_jsonl 记录、new 构造时取代表值。
  m[key_grade()] = Json::number(ev.grade_raw.to_double())
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
/// 从 JSON 值里取数字字段，并带回**原文**（`Json::Number` 的 `repr`）。
///
/// 只给 grade 用（RJ-A2，2026-11-10 审计）：JSON 数字解析成 Double 会
/// 丢失原文——2^53+1 与 2^53 在 Double 上是同一个值，越界守卫看不见。
/// 需要按字面判定「这是不是一个超过 2^53 的整数写法」时，只能看 repr。
fn field_number_with_repr(
  obj : Map[String, Json],
  key : String,
  line_no : Int32,
) -> (Double, String?) raise LogError {
  match obj.get(key) {
    Some(Number(n, repr~)) =>
      if n.is_nan() || (n - n).is_nan() {
        raise BadLine(
          line_no,
          "字段 \{key} 必须是有限数字，得到非有限值",
        )
      } else {
        (n, repr)
      }
    Some(_) => raise BadLine(line_no, "字段 \{key} 不是数字")
    None => raise BadLine(line_no, "缺少字段 \{key}")
  }
}

///|
/// 字面是否为**纯整数写法**（可带前导负号，无小数点/指数），若是则返回
/// 其十进制数字串（不含负号）；否则返回 None。
///
/// 只做形态判定，不做数值解析——数值交给调用方用 Int64 解析并在溢出时
/// 按「原文超界」处理。
fn integer_literal_digits(text : String) -> String? {
  let s = text.trim().to_owned()
  let body = if s.has_prefix("-") {
    s.substring(start=1, end=s.length())
  } else {
    s
  }
  if body == "" {
    return None
  }
  for c in body.to_array() {
    if c < '0' || c > '9' {
      return None
    }
  }
  Some(body)
}

///|
/// 用十进制数字串与 2^53 比较（避免 Int64 溢出：2^53 只有 16 位，
/// 更长的串一定更大）。
fn decimal_exceeds_2p53(digits : String) -> Bool {
  // 2^53 = 9007199254740992，共 16 位
  let t = if digits.length() > 1 && digits[0] == '0' {
    // 允许 "0009007199254740993" 这类前导零写法
    let mut i = 0
    while i < digits.length() - 1 && digits[i] == '0' {
      i = i + 1
    }
    digits.substring(start=i)
  } else {
    digits
  }
  if t.length() > 16 {
    return true
  }
  if t.length() < 16 {
    return false
  }
  // 同长度按字典序比较即可（数字串）
  t > "9007199254740992"
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
        raise BadLine(
          line_no,
          "字段 \{key} 必须是有限数字，得到非有限值",
        )
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
  let (grade_num, grade_repr) = field_number_with_repr(
    obj,
    key_grade(),
    line_no,
  )
  let elapsed = field_double(obj, key_elapsed_days(), line_no)
  let grade = Grade::from_int(@math.round(grade_num).to_int())
  // RJ-R：原始评分整数进入事件（无损日志）。四舍五入后的整数就是
  // 原文（JSON 数字一行一个值，grade 字段不存在小数形态的合法输入 ——
  // 1.5 会被 round 成 2 写回；这与「评分值是整数刻度」的契约一致）。
  //
  // RJ-1b（2026-11-08 审计）：grade_raw 用 Int64 承载。Int32 会把
  // 2500000000 饱和成 2147483647，首次往返即非恒等。JSON 数字是
  // Double，|原文| > 2^53 时 round 结果已不精确 —— 装不下就报错，
  // 与 elapsed_days 的有限性原则一致，不静默改值。
  let rounded = @math.round(grade_num)
  if rounded.is_nan() ||
    (rounded - rounded).is_nan() ||
    rounded < -9007199254740992.0 ||
    rounded > 9007199254740992.0 {
    raise BadLine(
      line_no,
      "字段 grade 必须是可精确表示的整数（|grade| ≤ 2^53），得到 \{grade_num}",
    )
  }
  // **字面原文校验**（RJ-A2，2026-11-10 审计）：2^53+1（奇数）在 Double
  // 上恰好等于 2^53（ties-to-even），上面的越界守卫看不见它 —— 于是
  // 首次往返就把 9007199254740993 静默改写成 ...992，违背「|grade| > 2^53
  // 报数据错误而不是静默改值」。纯整数写法必须按**原文**判容量：
  // 超过 2^53 直接拒收（含 2^53+1 这类会被向下吸收的奇数）。
  //
  // 带小数/指数的写法不受此限——round 归一化是文档化行为（1.5 → 2），
  // 不是静默改值。
  match grade_repr {
    Some(text) =>
      match integer_literal_digits(text) {
        Some(digits) =>
          if decimal_exceeds_2p53(digits) {
            raise BadLine(
              line_no,
              "字段 grade 必须是可精确表示的整数（|grade| ≤ 2^53），得到 \{text}",
            )
          }
        None => ()
      }
    None => ()
  }
  let grade_raw_val = rounded.to_int64()
  ReviewEvent::new_with_raw(
    card_id, reviewed_at, due_at, grade, grade_raw_val, elapsed,
  )
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
