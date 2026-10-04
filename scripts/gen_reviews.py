"""生成 recall 的示例复习日志。

设计要求（来自 recall-core 的审查意见）：

1. **elapsed_days 必须严格等于相邻事件 reviewed_at 的时间戳差 / 86400**
   否则 replay（用时间戳算间隔）与 retention_curve（用字段分桶）
   会给出互相矛盾的结论。

2. **保持率必须随间隔单调递减**
   做法不是「凑数」，而是让评分直接由遗忘曲线决定：
        R(t, S) = (1 + 19/81 * t/S) ^ -0.5
        P(grade = Again) = 1 - R(t, S)
   这样 lapses 天然集中在长间隔，曲线单调性是数据的必然结果，
   而不是算法的拟合假象。

3. **间隔要覆盖 1 天到约半年**，让 10 个分桶都有足够样本。

4. **10 张卡有不同特征稳定性**，体现算法在不同学习者上的差异。

5. 确定性生成（固定 seed 的 LCG），每次输出完全一致。
"""

import json

SECONDS_PER_DAY = 86400
BASE = 1700000000
DECAY_FACTOR = 19.0 / 81.0  # (19/81) 使 R(t=S) = 0.9


class LCG:
    """确定性伪随机，与 MoonBit 侧 simulate.mbt 用的是同类算法。"""

    def __init__(self, seed: int):
        self.state = seed & 0x7FFFFFFF

    def next(self) -> int:
        self.state = (self.state * 1103515245 + 12345) & 0x7FFFFFFF
        return self.state

    def uniform(self) -> float:
        return self.next() / 2147483647.0

    def randint(self, lo: int, hi: int) -> int:
        return lo + self.next() % (hi - lo + 1)

    def log_uniform(self, lo: float, hi: float) -> float:
        """对数均匀分布，让短间隔和长间隔都能被采到。"""
        a, b = __import__("math").log(lo), __import__("math").log(hi)
        return __import__("math").exp(a + (b - a) * self.uniform())


def retrievability(elapsed_days: float, stability: float) -> float:
    """FSRS 遗忘曲线。"""
    if stability <= 0:
        return 0.0
    return (1.0 + DECAY_FACTOR * elapsed_days / stability) ** -0.5


def sample_grade(r: float, rng: LCG) -> int:
    """按可提取性抽样评分。

    记得时偏向 Good，偶有 Easy；忘了时以 Again 为主。
    这样 grade 的分布直接反映 R，曲线单调性由数据保证。
    """
    if rng.uniform() < r:
        v = rng.uniform()
        if v < 0.12:
            return 5  # Easy
        elif v < 0.55:
            return 3  # Good
        else:
            return 4  # 偏 Easy
    else:
        return 0 if rng.uniform() < 0.82 else 2


def main() -> None:
    # 10 张卡，特征稳定性不同：从「极易忘」到「过目不忘」
    cards = [
        ("c1", 6.0, "轻松卡"),
        ("c2", 12.0, "正常"),
        ("c3", 3.0, "易忘卡"),
        ("c4", 40.0, "天生好记"),
        ("d1", 2.0, "困难卡"),
        ("d2", 18.0, "平稳"),
        ("d3", 5.0, "中等偏难"),
        ("e1", 1.5, "极不稳定"),
        ("e2", 28.0, "较快"),
        ("e3", 9.0, "常规"),
        ("f1", 7.0, "补充1"),
        ("f2", 15.0, "补充2"),
        ("f3", 4.0, "补充3"),
        ("f4", 22.0, "补充4"),
        ("f5", 1.2, "补充5"),
        ("f6", 33.0, "补充6"),
        ("f7", 11.0, "补充7"),
        ("f8", 2.5, "补充8"),
        ("f9", 19.0, "补充9"),
        ("f10", 6.5, "补充10"),
        ("g1", 5.5, "补充11"),
        ("g2", 25.0, "补充12"),
        ("g3", 3.5, "补充13"),
        ("g4", 14.0, "补充14"),
        ("g5", 8.0, "补充15"),
    ]

    rng = LCG(20241017)
    lines: list[str] = []

    for idx, (cid, stability, _note) in enumerate(cards):
        now = BASE + idx * 2 * SECONDS_PER_DAY

        for rep in range(30):
            if rep == 0:
                elapsed = 0.0
            else:
                # 间隔覆盖 1..180 天（对数均匀），保证 10 个分桶都有样本
                elapsed = round(rng.log_uniform(1.0, 180.0), 4)

            now = now + int(round(elapsed * SECONDS_PER_DAY))
            # 严格用时间戳反算，杜绝任何不一致
            if rep > 0:
                elapsed = (now - prev_now) / SECONDS_PER_DAY

            r = 1.0 if rep == 0 else retrievability(elapsed, stability)
            g = sample_grade(r, rng)

            # due_at 稍早于实际复习（模拟逾期）
            overdue_hours = rng.randint(0, max(1, int(elapsed * 6)))
            due_at = now - overdue_hours * 3600 - rng.randint(0, 600)

            rec = {
                "card_id": cid,
                "reviewed_at": now,
                "due_at": due_at,
                "grade": g,
                "elapsed_days": round(elapsed, 6),
            }
            lines.append(json.dumps(rec, separators=(",", ":"), ensure_ascii=False))
            prev_now = now

    with open("examples/reviews.jsonl", "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")

    # ---------- 自检 ----------
    by_card: dict[str, list] = {}
    for line in lines:
        rec = json.loads(line)
        by_card.setdefault(rec["card_id"], []).append(rec)

    mismatches = 0
    for cid, evs in by_card.items():
        for a, b in zip(evs, evs[1:]):
            actual = (b["reviewed_at"] - a["reviewed_at"]) / SECONDS_PER_DAY
            if abs(actual - b["elapsed_days"]) > 1e-6:
                mismatches += 1

    n = len(lines)
    lapses = sum(1 for line in lines if json.loads(line)["grade"] == 0)
    print(f"wrote {n} events across {len(by_card)} cards")
    print(f"  elapsed_days vs timestamp mismatches : {mismatches}  (must be 0)")
    print(f"  Again (lapse) count                  : {lapses} ({lapses / n * 100:.1f}%)")

    # 按 elapsed 分 10 桶，检查保持率单调性
    valid = [(json.loads(l)["elapsed_days"], json.loads(l)["grade"]) for l in lines]
    valid = [(e, g) for e, g in valid if e > 0]
    max_el = max(e for e, _ in valid)
    width = max_el / 10
    buckets = [0] * 10
    kept = [0] * 10
    for e, g in valid:
        b = min(9, int(e / width))
        buckets[b] += 1
        if g != 0:
            kept[b] += 1

    print("  retention by elapsed bucket:")
    rates = []
    for i in range(10):
        if buckets[i]:
            rate = kept[i] / buckets[i]
            rates.append(rate)
            bar = "#" * int(rate * 40)
            print(f"    < {(i + 1) * width:7.1f}d  n={buckets[i]:3d}  {rate * 100:5.1f}%  {bar}")

    mono = all(a >= b - 1e-9 for a, b in zip(rates, rates[1:]))
    print(f"  monotone non-increasing: {mono}")
    if not mono:
        print(f"    rates = {[round(x, 3) for x in rates]}")


if __name__ == "__main__":
    main()

