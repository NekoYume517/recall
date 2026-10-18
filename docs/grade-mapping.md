# Two integers that look the same and are not

`Grade` produces two different small integers. Substituting one for the other
has already caused a wrong result in this project, so the distinction is
written down separately.

## The two scales

| Grade | `Grade::to_int` (display) | `sm2_quality` (formula) |
|---|---|---|
| Again | 0 | 2 |
| Hard  | 2 | 3 |
| Good  | 3 | 4 |
| Easy  | 5 | 5 |

- `to_int` exists so that reports can print a 0..5 number, matching the scale
  users see in Anki's UI.
- `sm2_quality` exists so that SM-2's EF update can be evaluated.

**Only the second may be substituted into SM-2.**

## What goes wrong

For the sequence `Good, Good, Again, Good`:

```
q = 2  (correct)   EF: 2.50 -> 2.50 -> 2.18 -> 2.18
q = 0  (wrong)     EF: 2.50 -> 2.50 -> 1.70 -> 1.70
```

The difference is the EF delta:

```
q = 2:  0.1 - 3*(0.08 + 3*0.02) = 0.1 - 0.42 = -0.32
q = 0:  0.1 - 5*(0.08 + 5*0.02) = 0.1 - 0.90 = -0.80
```

`q = 0` is not even in the mapping table — it only arises from misreading
`to_int(Again) = 0` as the quality value.

## The related trap: what counts as a failure

SM-2 treats an answer as failed when `q < 3`. Since `Hard` has `q = 3`,
**Hard is a success** in SM-2.

Writing the predicate as `to_int() >= 3` therefore classifies Hard as a
failure, which contradicts the formula. That is why the project standardised
on:

```moonbit
pub fn is_recalled(g : Grade) -> Bool { g != Again }
```

Every consumer — SM-2, Leitner, stats, simulate — uses this one predicate, so
"did the learner remember it" has a single definition across the codebase.

## Where this is enforced

- `src/sm2_test.mbt` — four hand-computed tables, including the 2.18 case
- `src/types_test.mbt` — `is_pass` and `is_recalled` agree on all four grades
- `src/leitner_test.mbt` — Hard advances a box rather than resetting it
