///|
test "anki review regression: output uses lexical rather than length-first order" {
  let output = export_anki_tsv(
    [CardState::new("z", 0L), CardState::new("aa", 0L), CardState::new("a", 0L)],
    "fsrs",
  )
  let lines = output.split("\n").collect()
  assert_true(lines[4].has_prefix("a\t"))
  assert_true(lines[5].has_prefix("aa\t"))
  assert_true(lines[6].has_prefix("z\t"))
}

///|
test "anki review regression: lexical order is preserved for prefixes and Unicode" {
  let output = export_anki_tsv(
    [
      CardState::new("卡", 0L),
      CardState::new("a-long", 0L),
      CardState::new("#id", 0L),
    ],
    "fsrs",
  )
  let lines = output.split("\n").collect()
  assert_true(lines[4].has_prefix("\"#id\"\t"))
  assert_true(lines[5].has_prefix("a-long\t"))
  assert_true(lines[6].has_prefix("卡\t"))
}
