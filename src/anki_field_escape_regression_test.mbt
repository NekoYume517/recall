///|
test "anki review regression: tab and newline in IDs stay in one quoted field" {
  let output = export_anki_tsv([CardState::new("A\tB\nC", 0L)], "fsrs")
  assert_true(output.contains("\"A\tB\nC\"\t0\t0\t0\t0\t"))
}

///|
test "anki review regression: quotes and CR are escaped in IDs" {
  let output = export_anki_tsv([CardState::new("A\"B\rC", 0L)], "fsrs")
  assert_true(output.contains("\"A\"\"B\rC\"\t0\t0\t0\t0\t"))
}

///|
test "anki review regression: a comment-like ID remains a data row" {
  let output = export_anki_tsv([CardState::new("#A", 0L)], "fsrs")
  assert_true(output.contains("\"#A\"\t0\t0\t0\t0\t"))
}

///|
test "anki review regression: ordinary IDs preserve their existing representation" {
  let output = export_anki_tsv([CardState::new("卡片A", 0L)], "fsrs")
  assert_true(output.contains("\n卡片A\t0\t0\t0\t0\t"))
}
