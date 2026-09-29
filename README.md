# SQL Analytics Practice

A self-contained PostgreSQL environment for practising analytical SQL against a
synthetic loan portfolio. Clone it, run three scripts, and you have 2,000
customers, 3,000 loans and ~23,000 payments to query — no server access, no
credentials, no real data.

Everything here is generated. Names, amounts and dates are invented, and the
seed script is deterministic, so the numbers in this README are the numbers you
will get on your machine.

## Why this exists

Most public SQL exercises hand you clean data, which means the joins always
work and the edge cases never appear. This dataset is built with two properties
that mirror what production portfolios actually look like:

- **~16% of loans have no payment rows at all.** Any query that reaches for
  `INNER JOIN` by reflex silently drops them and understates the portfolio. No
  error is raised.
- **Payment histories are partial.** Loans stop paying at a random point in
  their term, so "last payment date" and "expected payment date" diverge.

The queries in `sql/03_analysis.sql` are written to survive both, and each one
carries a comment explaining the choice.

## Requirements

- PostgreSQL 14 or later
- Any SQL client (DBeaver, psql, pgAdmin)

## Setup

```bash
createdb sql_practice
psql -d sql_practice -f sql/01_schema.sql
psql -d sql_practice -f sql/02_seed_data.sql
```

From a GUI client, open each file and execute it as a script. Run them in order;
`01_schema.sql` drops and recreates the `practice` schema, so the whole thing is
safe to re-run from scratch at any point.

The seed script ends with a sanity check. Expected output:

```
 customers | loans | payments | loans_with_no_payment
-----------+-------+----------+-----------------------
      2000 |  3000 |    22907 |                   486
```

If your numbers differ, `setseed()` did not take effect — check that you ran the
whole file rather than individual statements.

## Contents

| File | What it holds |
| --- | --- |
| `sql/01_schema.sql` | Three tables, constraints, indexes |
| `sql/02_seed_data.sql` | Deterministic synthetic data generation |
| `sql/03_analysis.sql` | Six analysis queries, one technique each |

## Schema

```
customer ──< loan ──< payment
```

- `customer` — borrower, signup date, region
- `loan` — principal, origination date, term, rate; a customer may hold several
- `payment` — dated payments against a loan; may be absent entirely

## The queries

| # | Question | Technique |
| --- | --- | --- |
| 1 | How is outstanding balance distributed across delinquency buckets? | CTE chain, `LEFT JOIN` + `COALESCE`, `CASE` bucketing, window aggregate for share-of-total |
| 2 | Which loans have never received a payment? | Anti-join via `NOT EXISTS`, and why `NOT IN` fails silently on NULL |
| 3 | How does recovery rate vary by origination cohort? | `date_trunc` cohorts, pre-aggregation to avoid join fan-out, `LAG` for period-over-period |
| 4 | Where are the gaps in each loan's payment sequence? | `LAG` over a partition to measure intervals between consecutive rows |
| 5 | Top three borrowers by outstanding balance in each region? | `DENSE_RANK` in a partitioned window, filtered one level up |
| 6 | Why does subtracting 30 days differ from subtracting a month? | Interval vs integer date arithmetic, end-of-month clamping |

Sample output from query 1:

```
   bucket    | loans | outstanding_total | outstanding_avg | pct_of_portfolio
-------------+-------+-------------------+-----------------+------------------
 Current     |   701 |       13340259.59 |        19030.33 |            14.17
 30-59 days  |    71 |        2244653.01 |        31614.83 |             2.38
 60-89 days  |    81 |        2573607.61 |        31772.93 |             2.73
 90-179 days |   267 |        8862053.82 |        33191.21 |             9.41
 180+ days   |  1880 |       67147564.62 |        35716.79 |            71.31
```

## Try breaking it

The dataset is built so that common mistakes produce plausible wrong answers
rather than errors. Two worth running deliberately:

**Swap the `LEFT JOIN` in query 1 for an `INNER JOIN`.** The portfolio total
drops by roughly 16% and nothing complains. This is what a silent failure looks
like: the report still renders, the number is just wrong.

**Join `payment` directly in query 3 instead of pre-aggregating it.** Each loan
row is duplicated once per payment, so `sum(principal)` counts the same
principal repeatedly and the totals inflate by an arbitrary factor.

## Notes on dialect

Written for PostgreSQL. The syntax is close to Yellowbrick, Redshift and other
Postgres-compatible warehouses, but `generate_series` behaviour and window
function support vary across engines — verify before porting.

## License

MIT
