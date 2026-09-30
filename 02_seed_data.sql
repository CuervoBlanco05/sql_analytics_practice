-- ============================================================
-- 02_seed_data.sql — Synthetic data generation
--
-- Deterministic: setseed() fixes the PRNG so every run of this
-- file produces the identical dataset. That is what makes the
-- analysis results in the README reproducible on your machine.
--
-- All names, amounts and dates are invented.
-- ============================================================

SET search_path TO practice;

SELECT setseed(0.42);

-- ------------------------------------------------------------
-- Customers
-- ------------------------------------------------------------
INSERT INTO customer (customer_id, full_name, signup_date, region)
SELECT g,
       'Customer ' || lpad(g::text, 5, '0'),
       DATE '2023-01-01' + (random() * 700)::int,
       (ARRAY['North','South','East','West','Central'])[1 + floor(random() * 5)::int]
FROM generate_series(1, 2000) AS g;

-- ------------------------------------------------------------
-- Loans
-- ------------------------------------------------------------
-- Originations span roughly 2024-01 to 2026-08 so that, against a
-- 2026-09-30 cut-off, every delinquency bucket is populated.
INSERT INTO loan (loan_id, customer_id, principal, origination, term_months, annual_rate)
SELECT g,
       1 + floor(random() * 2000)::int,
       round((5000 + random() * 95000)::numeric, 2),
       DATE '2024-01-01' + (random() * 970)::int,
       (ARRAY[6,12,18,24,36])[1 + floor(random() * 5)::int],
       round((0.18 + random() * 0.42)::numeric, 4)
FROM generate_series(1, 3000) AS g;

-- ------------------------------------------------------------
-- Payments
--
-- Two deliberate properties of this data:
--   1. ~15% of loans receive no payment at all.
--   2. Loans that do pay stop at a random point in their term,
--      so payment histories are partial rather than complete.
--
-- Both are common in real portfolios and both break queries
-- that assume every loan has a payment row.
-- ------------------------------------------------------------
INSERT INTO payment (payment_id, loan_id, paid_on, amount)
SELECT row_number() OVER (ORDER BY l.loan_id, n),
       l.loan_id,
       l.origination + (n * 30),
       round((l.principal / l.term_months)::numeric, 2)
FROM (
    SELECT *, random() AS pay_roll, random() AS stop_roll
    FROM loan
) AS l
CROSS JOIN LATERAL generate_series(
    1,
    GREATEST(1, floor(l.stop_roll * l.term_months)::int)
) AS n
WHERE l.pay_roll < 0.85;

ANALYZE customer;
ANALYZE loan;
ANALYZE payment;

-- Sanity check — expected: 2000 customers, 3000 loans,
-- and a loans_with_no_payment count near 450.
SELECT (SELECT count(*) FROM customer) AS customers,
       (SELECT count(*) FROM loan)     AS loans,
       (SELECT count(*) FROM payment)  AS payments,
       (SELECT count(*) FROM loan l
        WHERE NOT EXISTS (SELECT 1 FROM payment p WHERE p.loan_id = l.loan_id))
                                       AS loans_with_no_payment;
