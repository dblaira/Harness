# Weakening Review Metric Integrity Check

Date: 2026-07-02

## Finding

Raw-count Pearson treated logging-volume spikes as belief changes. The refresh metric now uses `binary_above_median_week_phi`: each category is converted to yes/no for whether that week is above its own median count in that comparison window, then correlation is computed on those yes/no weekly series.

Plain English evidence line: "Metric: each category is yes/no for weeks above its own median, so logging-volume spikes do not dominate."

## Effect On The Seven Pending Cards

| Pair | Raw-count card | Robust was | Robust now | Verdict |
|---|---:|---:|---:|---|
| Affect and Learning | 67% to 8% | 28% | 23% | Drop does not survive |
| Ambition and Learning | 65% to 16% | 36% | 34% | Drop does not survive |
| Belief and Learning | 55% to 11% | 28% | 27% | Drop does not survive |
| Insight and Learning | 62% to 6% | 50% | 47% | Drop does not survive |
| Insight and Purchase | 66% to 48% | 52% | 51% | Drop does not survive |
| Learning and Purchase | 66% to 38% | 50% | 48% | Drop does not survive |
| Learning and Social | 61% to 48% | 40% | 37% | Drop does not survive |

## Queue Action

Cleared the seven pending raw-count weakening cards. The robust scan regenerated 0 weakening cards.

## Accepted Weakening Claims

No accepted `weakening_review` claims were found in `accepted-graph.ttl`, so no reversal-review correction cards were needed.

## Refresh Rule

Future weakening cards require robust baseline at or above 55% and robust current support below 50%, using the same binary-above-median metric for both windows.
