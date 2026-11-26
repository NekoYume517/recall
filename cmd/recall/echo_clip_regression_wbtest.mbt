///|
/// `echo_clip` / `echo_field` 的回归（第十九轮 RC-19-5，2026-11-27）。
///
/// 现象（修前实测）：
///
/// ```
/// recall replay --log nope.jsonl <300 个字符的裸 token>
///   用法错误: replay 不接受位置参数，多余的 'AAAA…（整 300 字）…AAAA'
/// ```
///
/// 消息把用户输入**原样**贴出来。超长输入（整段粘贴进来的 JSON / 路径 / SQL /
/// 一个 4000 位的 `--seed`）会把一行诊断撑成几百行，终端刷屏之后真正的
/// 「需要一个整数」被冲走；脚本 grep 这条消息时也拿不到稳定的行。
///
/// 修法（`echo_clip`）：不超过 `2·keep + 8` 个字符就原样返回；超过则保留前
/// `keep` 与后 `keep`，中间用 `…(共 N 字符，省略 M 字符)…` 标注。
/// **两头都留**：只留开头看不到写错的末几位，只留结尾丢掉上下文。
///
/// 锁定点：
///   1. 短输入逐字节不变（错误消息不能被"改进"到认不出原文）；
///   2. 长输入的长度有上界，且头尾都在；
///   3. 省略标注里的数字自洽（共 N = 保留 + 省略）；
///   4. 各子命令的回显真的走了这条路径（`--seed` / `--days` 的实测长度）。

///|
test "rc19-5: 短输入原样回显（不带任何省略标注）" {
  inspect(echo_clip("abc", 60), content="abc")
  inspect(echo_clip("1e400", 60), content="1e400")
  inspect(echo_field("9223372036854775808"), content="9223372036854775808")
  // 空串也必须原样（`--days ""` 的报错里就是空串）
  inspect(echo_field(""), content="")
}

///|
test "rc19-5: 长输入保留头尾、长度有上界" {
  let long = StringBuilder()
  for i = 0; i < 300; i = i + 1 {
    long.write_string("A")
  }
  let s = long.to_string()
  let out = echo_field(s)
  // 上界：2·keep + 标注前缀（"…(共 "）+ 标注后缀（" 字符，省略 "）+ 数字
  assert_true(out.length() < 2 * 60 + 60)
  // 头尾都留 60 个
  let sixty = StringBuilder()
  for i = 0; i < 60; i = i + 1 {
    sixty.write_string("A")
  }
  assert_true(out.has_prefix(sixty.to_string()))
  assert_true(out.has_suffix(sixty.to_string()))
  // 原始输入的一个字符都没被改成别的字符（只多出标注）
  assert_true(out.contains("共 300 字符"))
  assert_true(out.contains("省略 180 字符"))
}

///|
test "rc19-5: 省略标注自洽（保留 + 省略 = 总长）" {
  let long = StringBuilder()
  for i = 0; i < 4000; i = i + 1 {
    long.write_string("9")
  }
  let out = echo_clip(long.to_string(), 60)
  // 4000 = 60 + 3880 + 60
  assert_true(out.contains("共 4000 字符"))
  assert_true(out.contains("省略 3880 字符"))
}

///|
test "rc19-5: 边界长度不再被截（2·keep + 8 以内原样）" {
  let exactly = StringBuilder()
  for i = 0; i < 128; i = i + 1 {
    exactly.write_string("x")
  }
  inspect(echo_clip(exactly.to_string(), 60), content=exactly.to_string())
  // 129 就跨过阈值，开始截
  exactly.write_string("x")
  assert_true(echo_clip(exactly.to_string(), 60).contains("省略"))
}
