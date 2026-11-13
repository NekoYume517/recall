///|
/// 审计回归（2026-11-13 追加轮）：`simulate` 的**运行时工作预算**。
///
/// ## 为什么不是启动时公式
///
/// 前三道守卫（单轴 / 卡数乘积 / 扫描量）全部是「启动时按三个参数算一个数」。
/// 它们算不出**积压**：积压是运行时涌现的，由调度器给出的间隔分布与
/// `--days` × `--new-per-day` × `--review-limit` 三者交互决定。
/// 实测（native release，`--scheduler fsrs`，`new-per-day 20`、`days 2000`，
/// 只改 `--review-limit`；`probe/LEAD-COST-SURFACE.log` + `probe/grid-release.log`）：
///
///     rl=20   9.2 s   最终积压 39844
///     rl=50   7.0 s   最终积压 39275
///     rl=200  3.1 s   最终积压 22451
///     rl=500  0.3 s   最终积压 0
///     rl=2000 0.3 s   最终积压 0
///
/// 五组参数的扫描量 `new_per_day × days² / 2` **完全相同**（4e7），耗时差 30 倍；
/// 扫描量相同的 `--days 5000 --new-per-day 20 --review-limit 200` 在 release 要
/// 52.8 s、在 debug（`moon run`，DEMO 用的就是它）要 221 s。所以「`days × rl`」
/// 和「扫描量」都不是主导项 —— **积压能不能被 rl 消化**才是。
///
/// ## 判据（与墙钟无关）
///
/// 主循环每天累计「当天到期条数」`Σ due_cards`（= 当天要排序/处理的队列长度），
/// 超过预算就中止。这个量与实测耗时近似线性（release ~1e6–5e6 条/秒），
/// 而且**判定点完全由参数与种子决定**，同一配置两次运行在同一天、同一积压处中止。
///
/// 阈值取 `6e7`：文档里出现的每个 `simulate` 配置都远在它之下（最大 4.6e5，
/// 130 倍余量），而实测 ≥120 s 的那档（`Σ due ≥ 1e8`）会被拦下。
///
/// 注：这条用例只测预算机制本身（库函数 + 文案 + 双向性）；CLI 端到端
/// （`--days 5000 --new-per-day 20 --review-limit 200` 从 221 s 变成秒级 exit 2）
/// 由 `audit/2026-11-13/recall/REPORT.md` 的实测表记录。

///|
fn budget_cfg(days : Int32, n : Int32, rl : Int32) -> @lib.SimConfig {
  {
    days,
    new_per_day: n,
    review_limit: rl,
    desired_retention: 0.9,
    grade_fn: @lib.grade_policy_with_seed("realistic", 20240101L),
    seed: 20240101L,
  }
}

///|
test "budget: 预算内跑完时，结果与 simulate_with 逐字段相同" {
  let s = @lib.AnyScheduler::by_name("fsrs")
  // ⚠️ 每次跑都要新建配置：`grade_fn` 里的 LCG 有状态（API.md §5.1 的
  // `policy_factory` 注释），复用同一个 cfg 会让第二次跑从被推进过的
  // 随机流开始，两次结果天然不同。
  let plain = @lib.simulate_with(s, budget_cfg(60, 5, 50))
  match @lib.simulate_with_budget(s, budget_cfg(60, 5, 50), 60000000L) {
    @lib.Completed(r) => {
      inspect(r.days.length() == plain.days.length(), content="true")
      inspect(r.total_reviews == plain.total_reviews, content="true")
      inspect(r.final_backlog == plain.final_backlog, content="true")
      for i, d in r.days {
        inspect(d.due_cards == plain.days[i].due_cards, content="true")
        inspect(d.backlog == plain.days[i].backlog, content="true")
      }
    }
    @lib.Aborted(_) => inspect("aborted", content="completed")
  }
}

///|
test "budget: 超预算时中止，可重复（同参数两次同一天、同一积压）" {
  let s = @lib.AnyScheduler::by_name("fsrs")
  let budget : Int64 = 150000L
  let a = @lib.simulate_with_budget(s, budget_cfg(300, 20, 10), budget)
  let b = @lib.simulate_with_budget(s, budget_cfg(300, 20, 10), budget)
  match a {
    @lib.Completed(_) => inspect("completed", content="aborted")
    @lib.Aborted(x) =>
      match b {
        @lib.Completed(_) => inspect("completed", content="aborted")
        @lib.Aborted(y) => {
          inspect(x.day, content=y.day.to_string())
          inspect(x.backlog, content=y.backlog.to_string())
          inspect(x.due_cards, content=y.due_cards.to_string())
          inspect(x.work, content=y.work.to_string())
          inspect(x.work > budget, content="true")
          inspect(x.limit, content="150000")
          let m1 = simulate_budget_error(x, 300, 20, 10)
          let m2 = simulate_budget_error(y, 300, 20, 10)
          inspect(m1, content=m2)
        }
      }
  }
}

///|
test "budget: 建议的 --days 上界双向成立（d 通过、d+1 在同一位置中止）" {
  let s = @lib.AnyScheduler::by_name("fsrs")
  let budget : Int64 = 150000L
  match @lib.simulate_with_budget(s, budget_cfg(300, 20, 10), budget) {
    @lib.Completed(_) => inspect("completed", content="aborted")
    @lib.Aborted(x) => {
      // 建议值：--days = x.day（覆盖第 0..x.day-1 天，预算在第 x.day 天才超）
      let ok = @lib.simulate_with_budget(s, budget_cfg(x.day, 20, 10), budget)
      match ok {
        @lib.Completed(r) => inspect(r.days.length(), content=x.day.to_string())
        @lib.Aborted(_) => inspect("aborted", content="completed")
      }
      // 再多一天：同一位置再次中止
      let more = @lib.simulate_with_budget(
        s,
        budget_cfg(x.day + 1, 20, 10),
        budget,
      )
      match more {
        @lib.Completed(_) => inspect("completed", content="aborted")
        @lib.Aborted(y) => inspect(y.day, content=x.day.to_string())
      }
    }
  }
}

///|
test "budget: 预算为 0 在第 0 天立即中止（不是不限）" {
  let s = @lib.AnyScheduler::by_name("fsrs")
  match @lib.simulate_with_budget(s, budget_cfg(10, 5, 50), 0L) {
    @lib.Completed(_) => inspect("completed", content="aborted")
    @lib.Aborted(x) => {
      inspect(x.day, content="0")
      inspect(x.limit, content="0")
      inspect(x.work > 0L, content="true")
    }
  }
}

///|
test "budget: 文档里的 simulate 配置全部在预算内跑完" {
  let s = @lib.AnyScheduler::by_name("fsrs")
  // README §快速开始 / README §命令 / API.md §7 / DEMO §2
  match @lib.simulate_with_budget(s, budget_cfg(90, 20, 200), 60000000L) {
    @lib.Completed(r) => inspect(r.total_reviews, content="7706")
    @lib.Aborted(_) => inspect("aborted", content="completed")
  }
  // DEMO §2 第二例
  match @lib.simulate_with_budget(s, budget_cfg(90, 20, 50), 60000000L) {
    @lib.Completed(r) => inspect(r.final_backlog, content="1294")
    @lib.Aborted(_) => inspect("aborted", content="completed")
  }
  // DEMO §3
  match @lib.simulate_with_budget(s, budget_cfg(60, 20, 30), 60000000L) {
    @lib.Completed(r) => inspect(r.final_backlog, content="966")
    @lib.Aborted(_) => inspect("aborted", content="completed")
  }
}

///|
test "budget: 中止文案给出预算、进度、两条可执行建议" {
  let abort : @lib.SimAbort = {
    day: 1500,
    backlog: 45000,
    due_cards: 45123,
    work: 60123456L,
    limit: 60000000L,
  }
  let msg = simulate_budget_error(abort, 5000, 20, 200)
  assert_true(msg.contains("60000000"))
  assert_true(msg.contains("60123456"))
  assert_true(msg.contains("1501"))
  assert_true(msg.contains("45123"))
  assert_true(msg.contains("45000"))
  assert_true(msg.contains("--review-limit 200"))
  // 建议一：--days 降到中止那天之前（= abort.day）
  assert_true(msg.contains("--days 降到 1500"))
  // 建议二：--review-limit 0（不限）
  assert_true(msg.contains("--review-limit 0"))
  assert_true(msg.contains("用法错误"))
}

///|
test "budget: 第 0 天就中止时不给「--days 降到 0」这种不可执行建议" {
  let abort : @lib.SimAbort = {
    day: 0,
    backlog: 999999,
    due_cards: 1000000,
    work: 1000000L,
    limit: 500000L,
  }
  let msg = simulate_budget_error(abort, 90, 100000, 200)
  assert_true(!msg.contains("--days 降到 0"))
  assert_true(msg.contains("--new-per-day"))
}
