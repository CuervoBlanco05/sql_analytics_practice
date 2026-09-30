-- ============================================================
-- 03_analysis.sql — Portfolio analysis
--
-- Each query states the business question it answers and the
-- SQL technique it demonstrates. Run them one at a time.
-- ============================================================

SET search_path TO practice;

-- ------------------------------------------------------------
-- Q1. How is outstanding balance distributed across
--     delinquency buckets as of the cut-off date?
--
-- Technique: CTE chain, LEFT JOIN with COALESCE, CASE bucketing,
--            window aggregate for share-of-total.
--
-- The LEFT JOIN is load-bearing. Loans with no payments have no
-- row in last_payment; an INNER JOIN would silently drop them and
-- understate the portfolio by roughly 16% — without raising an
-- error, which is what makes the mistake expensive.
-- ------------------------------------------------------------
WITH cutoff AS (
    SELECT DATE '2026-09-30' AS as_of
),
last_payment AS (
    SELECT loan_id,
           max(paid_on) AS last_paid_on,
           sum(amount)  AS total_paid
    FROM payment
    GROUP BY loan_id
),
balance AS (
    SELECT l.loan_id,
           l.customer_id,
           l.principal,
           COALESCE(p.total_paid, 0)              AS total_paid,
           l.principal - COALESCE(p.total_paid, 0) AS outstanding,
           COALESCE(p.last_paid_on, l.origination) AS reference_date
    FROM loan l
    LEFT JOIN last_payment p ON p.loan_id = l.loan_id
),
bucketed AS (
    SELECT b.*,
           (SELECT as_of FROM cutoff) - b.reference_date AS days_since_activity,
           CASE
               WHEN (SELECT as_of FROM cutoff) - b.reference_date <  30 THEN 'Current'
               WHEN (SELECT as_of FROM cutoff) - b.reference_date <  60 THEN '30-59 days'
               WHEN (SELECT as_of FROM cutoff) - b.reference_date <  90 THEN '60-89 days'
               WHEN (SELECT as_of FROM cutoff) - b.reference_date < 180 THEN '90-179 days'
               ELSE '180+ days'
           END AS bucket
    FROM balance b
)
SELECT bucket,
       count(*)                                  AS loans,
       round(sum(outstanding), 2)                AS outstanding_total,
       round(avg(outstanding), 2)                AS outstanding_avg,
       round(100.0 * sum(outstanding)
             / sum(sum(outstanding)) OVER (), 2) AS pct_of_portfolio
FROM bucketed
WHERE outstanding > 0
GROUP BY bucket
ORDER BY min(days_since_activity);


-- ------------------------------------------------------------
-- Q2. Which loans have never received a payment?
--
-- Technique: anti-join via NOT EXISTS.
--
-- NOT EXISTS is the safe form. NOT IN against a subquery that can
-- return NULL evaluates to UNKNOWN for every row and yields an
-- empty result instead of an error — a silent failure mode.
-- ------------------------------------------------------------
SELECT l.loan_id,
       l.customer_id,
       l.principal,
       l.origination,
       CURRENT_DATE - l.origination AS days_outstanding
FROM loan l
WHERE NOT EXISTS (
    SELECT 1 FROM payment p WHERE p.loan_id = l.loan_id
)
ORDER BY l.origination
LIMIT 50;


-- ------------------------------------------------------------
-- Q3. How does recovery rate vary by origination cohort?
--
-- Technique: date_trunc for cohort grouping, ratio of aggregates,
--            LAG to compare each vintage against the previous one.
--
-- Payments are aggregated to one row per loan BEFORE joining. Join
-- the raw payment table instead and each loan row is duplicated
-- once per payment, so sum(principal) counts the same principal
-- many times over — the classic fan-out. The query still returns
-- results; they are just inflated by an arbitrary factor.
--
-- Ratio of sums, not average of ratios: avg(paid/principal) weights
-- a $5k loan the same as a $95k one and answers a different
-- question than the portfolio-level recovery rate.
-- ------------------------------------------------------------
WITH paid_per_loan AS (
    SELECT loan_id, sum(amount) AS collected
    FROM payment
    GROUP BY loan_id
),
vintage AS (
    SELECT date_trunc('month', l.origination)::date AS cohort_month,
           count(*)                                 AS loans,
           sum(l.principal)                         AS principal_total,
           COALESCE(sum(pl.collected), 0)           AS collected_total
    FROM loan l
    LEFT JOIN paid_per_loan pl ON pl.loan_id = l.loan_id
    GROUP BY 1
)
SELECT cohort_month,
       loans,
       round(principal_total, 2)                    AS principal_total,
       round(collected_total, 2)                    AS collected_total,
       round(100.0 * collected_total
             / NULLIF(principal_total, 0), 2)       AS recovery_pct,
       round(100.0 * collected_total / NULLIF(principal_total, 0)
             - LAG(100.0 * collected_total / NULLIF(principal_total, 0))
               OVER (ORDER BY cohort_month), 2)     AS pct_change_vs_prior
FROM vintage
ORDER BY cohort_month;


-- ------------------------------------------------------------
-- Q4. Where are the gaps in each loan's payment sequence?
--
-- Technique: LAG over a partition to compute the interval between
--            consecutive payments on the same loan.
--
-- A gap materially longer than the usual cadence is the signal
-- worth surfacing: it marks a loan that went delinquent and then
-- resumed, which a single "last payment date" column hides.
-- ------------------------------------------------------------
WITH spaced AS (
    SELECT loan_id,
           paid_on,
           amount,
           LAG(paid_on) OVER (PARTITION BY loan_id ORDER BY paid_on) AS prior_paid_on,
           paid_on - LAG(paid_on) OVER (PARTITION BY loan_id ORDER BY paid_on) AS days_since_prior,
           row_number() OVER (PARTITION BY loan_id ORDER BY paid_on) AS payment_seq
    FROM payment
)
SELECT loan_id,
       payment_seq,
       prior_paid_on,
       paid_on,
       days_since_prior
FROM spaced
WHERE days_since_prior > 45
ORDER BY days_since_prior DESC, loan_id
LIMIT 50;


-- ------------------------------------------------------------
-- Q5. Who are the top three borrowers by outstanding balance
--     within each region?
--
-- Technique: aggregation, then DENSE_RANK in a window partitioned
--            by region, filtered in an outer query.
--
-- Window functions cannot appear in WHERE — they are evaluated
-- after it — so the rank has to be computed in a subquery and
-- filtered one level up.
-- ------------------------------------------------------------
WITH customer_balance AS (
    SELECT c.customer_id,
           c.full_name,
           c.region,
           sum(l.principal) - COALESCE(sum(p.paid), 0) AS outstanding
    FROM customer c
    JOIN loan l ON l.customer_id = c.customer_id
    LEFT JOIN (
        SELECT loan_id, sum(amount) AS paid
        FROM payment
        GROUP BY loan_id
    ) p ON p.loan_id = l.loan_id
    GROUP BY c.customer_id, c.full_name, c.region
),
ranked AS (
    SELECT cb.*,
           DENSE_RANK() OVER (PARTITION BY region ORDER BY outstanding DESC) AS rank_in_region
    FROM customer_balance cb
    WHERE outstanding > 0
)
SELECT region,
       rank_in_region,
       customer_id,
       full_name,
       round(outstanding, 2) AS outstanding
FROM ranked
WHERE rank_in_region <= 3
ORDER BY region, rank_in_region;


-- ------------------------------------------------------------
-- Q6. Date arithmetic: subtracting days is not subtracting months.
--
-- Technique: interval vs integer arithmetic on dates.
--
-- On a 31-day month the two differ by three days, and Postgres
-- clamps an overflowing day-of-month to the last valid day. A
-- delinquency window written as `- 30` instead of
-- `- INTERVAL '1 month'` shifts loans between buckets with no
-- error raised anywhere.
-- ------------------------------------------------------------
SELECT DATE '2026-03-31'                             AS base,
       DATE '2026-03-31' - 30                        AS minus_30_days,
       (DATE '2026-03-31' - INTERVAL '1 month')::date AS minus_1_month,
       DATE '2026-01-31' + INTERVAL '1 month'        AS jan_31_plus_month;

-- For month boundaries, derive them rather than subtracting days.
SELECT date_trunc('month', DATE '2026-09-29')::date AS month_start,
       (date_trunc('month', DATE '2026-09-29')
        + INTERVAL '1 month' - INTERVAL '1 day')::date AS month_end;
