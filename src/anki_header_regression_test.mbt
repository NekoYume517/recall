///|
test "anki review regression: columns follow the declared tab separator" {
  let output = export_anki_tsv([CardState::new("A", 0L)], "fsrs")
  let lines = output.split("\n").collect()
  assert_eq(lines[0], "#separator:tab")
  assert_eq(lines[3].split("\t").collect().length(), 8)
}

///|
test "anki review regression: scheduler metadata is a comment not a note type" {
  let output = export_anki_tsv([], "fsrs")
  assert_true(output.contains("# scheduler: fsrs\n"))
  assert_true(!output.contains("#note-type:"))
  assert_true(!output.contains("#notetype:"))
}

///|
test "anki review regression: metadata cannot inject new physical header lines" {
  let output = export_anki_tsv([], "custom\nnotetype:evil\rline")
  assert_eq(output.split("\n").collect().length(), 5)
  assert_true(output.contains("# scheduler: custom\\nnotetype:evil\\rline\n"))
}
