-- ============================================================
-- 01_schema.sql — Loan portfolio schema
-- Engine: PostgreSQL 14+
--
-- Run order: 01_schema.sql -> 02_seed_data.sql -> 03_analysis.sql
-- Safe to re-run: drops and recreates the `practice` schema.
-- ============================================================

DROP SCHEMA IF EXISTS practice CASCADE;
CREATE SCHEMA practice;
SET search_path TO practice;

-- Borrowers.
CREATE TABLE customer (
    customer_id integer PRIMARY KEY,
    full_name   text    NOT NULL,
    signup_date date    NOT NULL,
    region      text    NOT NULL
);

-- One row per loan. A customer may hold several.
CREATE TABLE loan (
    loan_id        integer       PRIMARY KEY,
    customer_id    integer       NOT NULL REFERENCES customer(customer_id),
    principal      numeric(12,2) NOT NULL CHECK (principal > 0),
    origination    date          NOT NULL,
    term_months    integer       NOT NULL CHECK (term_months > 0),
    annual_rate    numeric(5,4)  NOT NULL
);

-- Payment history. A loan may legitimately have zero rows here —
-- that case is what makes INNER JOIN the wrong default (see 03).
CREATE TABLE payment (
    payment_id  bigint        PRIMARY KEY,
    loan_id     integer       NOT NULL REFERENCES loan(loan_id),
    paid_on     date          NOT NULL,
    amount      numeric(12,2) NOT NULL CHECK (amount > 0)
);

CREATE INDEX idx_payment_loan     ON payment (loan_id);
CREATE INDEX idx_payment_paid_on  ON payment (paid_on);
CREATE INDEX idx_loan_customer    ON loan (customer_id);
CREATE INDEX idx_loan_origination ON loan (origination);

COMMENT ON SCHEMA practice IS 'Synthetic loan portfolio for SQL analytics practice. No real data.';
