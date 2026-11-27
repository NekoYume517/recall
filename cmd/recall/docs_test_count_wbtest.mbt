// 文档里硬编码的用例总数必须与一个**仓库内可读**的声明同源
// （第二十二轮 RC-22-5，2026-11-30）
//
// 现象：docs/DEMO.md 第 25 行与第 29 行各写了一个硬编码用例数：
//
//   moon test      # 738 个测试
//   预期：`Total tests: 738, passed: 738, failed: 0.`
//
// 而实际 `moon test --release` 报 `Total tests: 749`。DEMO.md 自己在那两行下面
// 就写着「这一行是**硬编码的期望值**：每加一条测试都要跟着改」——这句自述正是
// 缺陷：一个只能靠人记住的数字，必然漂移。历史记录里它至少错过一次（482 vs 510）。
//
// 「凡写进文档的数字必须能从实现常量算出来」（纪律 9）。用例总数不能由本仓库
// 在运行时数出来（测试数量是 `moon test` 的运行时事实，库代码看不见），所以
// 只能退一步：把那个数变成一个**单一事实源**（常量），并让测试断言两边一致。
// 两边再一起漂，就没人拦得住。
//
// 做法：
//   1. 新增 `docs_test_count()` 作为唯一权威声明（cmd/recall/main.mbt 旁边，
//      与其它 `cli_*` 常量同族）；
//   2. 本测试断言 DEMO.md 里出现的**每一处**用例总数都等于它——不是「至少
//      有一处」，是**全部**（漏改一处的老毛病就是这么长出来的）；
//   3. 反向：DEMO.md 里不得再出现除该值之外的「N 个测试 / Total tests: N」
//      形态的数字，否则下一轮加测试时又只改常量、文档留旧值。
//
// 判据是双向的：常量改了文档没改 ⇒ 红；文档多写一个旧数字 ⇒ 也红。

///|
/// 从一段文本里抽出所有「N 个测试」与「Total tests: N」形态的计数。
fn rc22_doc_counts(text : String) -> Array[Int32] {
  let out : Array[Int32] = []
  // 逐字符扫描：遇到数字就收集整段，再看后面跟着的是不是那两个标记之一。
  let mut i = 0
  let n = text.length()
  while i < n {
    let ch = text[i]
    if ch >= '0' && ch <= '9' {
      let sb = StringBuilder()
      let mut j = i
      while j < n && text[j] >= '0' && text[j] <= '9' {
        if text.get_char(j) is Some(c2) {
          sb.write_char(c2)
        }
        j = j + 1
      }
      let tail = text[j:].to_owned()
      let is_test_count = tail.has_prefix(" 个测试") ||
        tail.has_prefix(", passed: ")
      if is_test_count {
        match parse_int_loose(sb.to_string()) {
          Some(v) => out.push(v)
          None => ()
        }
      }
      i = j
    } else {
      i = i + 1
    }
  }
  out
}

///|
test "RC-22-5: docs/DEMO.md 里每一处用例总数都等于权威声明" {
  let text = @fs.read_file_to_string("docs/DEMO.md")
  let counts = rc22_doc_counts(text)
  println("counts=" + counts.to_string())
  assert_true(counts.length() > 0)
  for c in counts {
    assert_eq(c, docs_test_count())
  }
}

///|
test "RC-22-5b: 权威声明本身不是 0（反向判据：不许用 0 蒙过上面那条）" {
  assert_true(docs_test_count() > 700)
  // 抽取器必须真的能认出那两种形态——用构造文本自证，否则上面那条可能因为
  // 「一个都没抽到」而「全部相等」地通过（德摩根陷阱）。
  let probe = "moon test      # 123 个测试\n预期：`Total tests: 456, passed: 456"
  let got = rc22_doc_counts(probe)
  println("probe=" + got.to_string())
  assert_eq(got.length(), 2)
  assert_eq(got[0], 123)
  assert_eq(got[1], 456)
}
