# Weakening Review Metric Integrity Check

Date: 2026-07-02

## Finding

The pending weakening-review cards are not using mismatched math.

The accepted March-derived "was" values reproduce as Pearson correlation over weekly category counts on the March window ending 2026-03-01. The refresh "now" values also use Pearson correlation over weekly category counts on the trusted window, now covering 2024-05-27 to 2026-03-29.

The word "co-rose" in older evidence text was misleading. The ingest script now names the metric explicitly as `pearson_weekly_counts` and writes evidence as "Pearson correlation ...".

## Pending Weakening Cards

| Pair | Was | Now corrected | Verdict |
|---|---:|---:|---|
| Affect and Learning | 67% | 8% | Still weakening; card math is valid |
| Ambition and Learning | 65% | 16% | Still weakening; card math is valid |
| Belief and Learning | 55% | 11% | Still weakening; card math is valid |
| Insight and Learning | 62% | 6% | Still weakening; card math is valid |
| Insight and Purchase | 66% | 48% | Still weakening; card math is valid |
| Learning and Purchase | 66% | 38% | Still weakening; card math is valid |
| Learning and Social | 61% | 48% | Still weakening; card math is valid |

No pending weakening card was cleared. The live queue evidence text was updated to say "Pearson correlation" without changing the numbers.

## Accepted Weakening Claims

No accepted `weakening_review` claims were found in `accepted-graph.ttl`, so no reversal-review correction cards were queued.

## All Accepted Observed Correlations

| Pair | Was | Now corrected | Verdict |
|---|---:|---:|---|
| Affect and Ambition | 56% | 93% | At/above 50%; no weakening review |
| Affect and Belief | 53% | 96% | At/above 50%; no weakening review |
| Affect and Insight | 54% | 98% | At/above 50%; no weakening review |
| Affect and Learning | 67% | 8% | Below 50%; weakening review warranted |
| Affect and Purchase | 51% | 53% | At/above 50%; no weakening review |
| Affect and Social | 63% | 62% | At/above 50%; no weakening review |
| Affect and Work | 53% | 87% | At/above 50%; no weakening review |
| Ambition and Belief | 59% | 93% | At/above 50%; no weakening review |
| Ambition and Health | 59% | 59% | At/above 50%; no weakening review |
| Ambition and Insight | 62% | 90% | At/above 50%; no weakening review |
| Ambition and Learning | 65% | 16% | Below 50%; weakening review warranted |
| Ambition and Purchase | 56% | 69% | At/above 50%; no weakening review |
| Ambition and Social | 66% | 66% | At/above 50%; no weakening review |
| Ambition and Work | 53% | 90% | At/above 50%; no weakening review |
| Belief and Insight | 55% | 96% | At/above 50%; no weakening review |
| Belief and Learning | 55% | 11% | Below 50%; weakening review warranted |
| Belief and Purchase | 55% | 55% | At/above 50%; no weakening review |
| Belief and Social | 60% | 60% | At/above 50%; no weakening review |
| Belief and Work | 55% | 89% | At/above 50%; no weakening review |
| Exercise and Sleep | 57% | 59% | At/above 50%; no weakening review |
| Focus and Sleep | 42% | n/a | Cannot recompute from trusted categories |
| Health and Purchase | 70% | 70% | At/above 50%; no weakening review |
| Health and Social | 57% | 57% | At/above 50%; no weakening review |
| Health and Work | 57% | 57% | At/above 50%; no weakening review |
| Insight and Learning | 62% | 6% | Below 50%; weakening review warranted |
| Insight and Purchase | 66% | 48% | Below 50%; weakening review warranted |
| Insight and Social | 56% | 56% | At/above 50%; no weakening review |
| Insight and Work | 83% | 83% | At/above 50%; no weakening review |
| Learning and Purchase | 66% | 38% | Below 50%; weakening review warranted |
| Learning and Social | 61% | 48% | Below 50%; weakening review warranted |
| Purchase and Social | 57% | 57% | At/above 50%; no weakening review |
| Purchase and Work | 62% | 62% | At/above 50%; no weakening review |
| Social and Work | 59% | 72% | At/above 50%; no weakening review |

Note: `Focus and Sleep` appears in the accepted graph but is outside the 13 trusted Supabase life categories used by this ingest pass, so it could not be recomputed here.
