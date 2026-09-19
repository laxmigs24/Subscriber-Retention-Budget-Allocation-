-- ============================================================================
-- 01_clean_transactions.sql
--
-- Purpose : Deduplicate the transaction table, then isolate the single
--           transaction that set each cohort subscriber's March 2017 expiry.
--           Everything downstream hangs off expiry_anchor.
--
-- Inputs  : transactions, labels        (built by src/01_sample_and_load.py)
-- Outputs : tx_clean, expiry_anchor
--
-- Run     : sqlite3 data/kkbox.db < sql/01_clean_transactions.sql
--
-- Date convention: dates are stored as INTEGER YYYYMMDD, matching the source.
-- Window boundaries are computed here, once, and stored as integers so that
-- downstream range joins stay index-friendly.
-- ============================================================================

PRAGMA foreign_keys = OFF;


-- ----------------------------------------------------------------------------
-- 1. Deduplicate transactions
--
-- Only EXACT duplicates are removed — rows identical across every field.
-- Rows sharing (msno, transaction_date) but differing in price, plan or cancellation status are legitimate same-day events and are kept. 
-- Collapsing those would silently discard cancellations.
-- ----------------------------------------------------------------------------

DROP TABLE IF EXISTS tx_clean;

CREATE TABLE tx_clean AS
WITH ranked AS (
    SELECT
        msno,
        payment_method_id,
        payment_plan_days,
        plan_list_price,
        actual_amount_paid,
        is_auto_renew,
        transaction_date,
        membership_expire_date,
        is_cancel,
        ROW_NUMBER() OVER (
            PARTITION BY
                msno, payment_method_id, payment_plan_days,
                plan_list_price, actual_amount_paid, is_auto_renew,
                transaction_date, membership_expire_date, is_cancel
            ORDER BY rowid
        ) AS dup_rn
    FROM transactions
)
SELECT
    msno,
    payment_method_id,
    payment_plan_days,
    plan_list_price,
    actual_amount_paid,
    is_auto_renew,
    transaction_date,
    membership_expire_date,
    is_cancel
FROM ranked
WHERE dup_rn = 1;

CREATE INDEX idx_tx_clean_msno_date ON tx_clean (msno, transaction_date);
CREATE INDEX idx_tx_clean_expire    ON tx_clean (membership_expire_date);


-- ----------------------------------------------------------------------------
-- 2. Expiry anchor
--
-- The anchor is the transaction that established the subscriber's March 2017
-- expiry date. Selection rule, in order:
--
--   1. Candidate rows must have membership_expire_date in March 2017 AND
--      transaction_date <= membership_expire_date. The second condition is a
--      LEAKAGE GUARD: a transaction dated after expiry is the renewal itself,
--      which is the outcome we are predicting.
--   2. Latest transaction_date wins.
--   3. On a tie, the purchase row wins over the cancellation row
--      (is_cancel ASC), so plan and price describe what was bought.
--   4. Remaining ties broken by the longer resulting membership.
--
-- Cancellations are not discarded — they are carried as flags, because
-- cancelling is not the same as churning and may itself be a signal.
-- ----------------------------------------------------------------------------

DROP TABLE IF EXISTS expiry_anchor;

CREATE TABLE expiry_anchor AS
WITH cohort_tx AS (
    SELECT t.*
    FROM tx_clean t
    JOIN labels  l ON l.msno = t.msno
    WHERE t.membership_expire_date BETWEEN 20170301 AND 20170331
      AND t.transaction_date <= t.membership_expire_date
),

ranked AS (
    SELECT
        c.*,
        ROW_NUMBER() OVER (
            PARTITION BY msno
            ORDER BY
                transaction_date       DESC,
                is_cancel              ASC,
                membership_expire_date DESC
        ) AS rn
    FROM cohort_tx c
),

anchor AS (
    SELECT * FROM ranked WHERE rn = 1
),

cancel_flags AS (
    SELECT
        a.msno,
        MAX(CASE WHEN c.is_cancel = 1
                  AND c.transaction_date = a.transaction_date
                 THEN 1 ELSE 0 END) AS cancel_on_anchor_date,
        MAX(CASE WHEN c.is_cancel = 1 THEN 1 ELSE 0 END) AS cancel_before_expiry,
        SUM(CASE WHEN c.is_cancel = 1 THEN 1 ELSE 0 END) AS cancel_events_in_cohort
    FROM anchor   a
    JOIN cohort_tx c ON c.msno = a.msno
    GROUP BY a.msno
)

SELECT
    a.msno,

    -- the expiry itself
    a.membership_expire_date                        AS expiry_date,
    date(substr(CAST(a.membership_expire_date AS TEXT), 1, 4) || '-' ||
         substr(CAST(a.membership_expire_date AS TEXT), 5, 2) || '-' ||
         substr(CAST(a.membership_expire_date AS TEXT), 7, 2))
                                                    AS expiry_date_iso,

    -- what the subscriber bought
    a.transaction_date                              AS anchor_transaction_date,
    a.payment_method_id,
    a.payment_plan_days,
    a.plan_list_price,
    a.actual_amount_paid,
    a.is_auto_renew,
    a.is_cancel                                     AS anchor_is_cancel,

    -- cancellation context
    COALESCE(f.cancel_on_anchor_date,   0)          AS cancel_on_anchor_date,
    COALESCE(f.cancel_before_expiry,    0)          AS cancel_before_expiry,
    COALESCE(f.cancel_events_in_cohort, 0)          AS cancel_events_in_cohort,

    -- behavioural window boundaries, computed once, as integers
    CAST(strftime('%Y%m%d',
        date(substr(CAST(a.membership_expire_date AS TEXT), 1, 4) || '-' ||
             substr(CAST(a.membership_expire_date AS TEXT), 5, 2) || '-' ||
             substr(CAST(a.membership_expire_date AS TEXT), 7, 2), '-30 day')
    ) AS INTEGER)                                   AS window30_start,

    CAST(strftime('%Y%m%d',
        date(substr(CAST(a.membership_expire_date AS TEXT), 1, 4) || '-' ||
             substr(CAST(a.membership_expire_date AS TEXT), 5, 2) || '-' ||
             substr(CAST(a.membership_expire_date AS TEXT), 7, 2), '-56 day')
    ) AS INTEGER)                                   AS window56_start

FROM anchor       a
LEFT JOIN cancel_flags f ON f.msno = a.msno;

CREATE UNIQUE INDEX idx_anchor_msno ON expiry_anchor (msno);


-- ============================================================================
-- VALIDATION — read these before running 02.
-- ============================================================================

SELECT '--- 1. deduplication ---' AS check_name;

SELECT
    (SELECT COUNT(*) FROM transactions) AS rows_in,
    (SELECT COUNT(*) FROM tx_clean)     AS rows_out,
    (SELECT COUNT(*) FROM transactions)
      - (SELECT COUNT(*) FROM tx_clean) AS exact_duplicates_removed;


SELECT '--- 2. anchor coverage (expect a small unmatched count, not zero) ---' AS check_name;

SELECT
    (SELECT COUNT(*) FROM labels)        AS cohort_subscribers,
    (SELECT COUNT(*) FROM expiry_anchor) AS with_anchor,
    (SELECT COUNT(*) FROM labels)
      - (SELECT COUNT(*) FROM expiry_anchor) AS without_anchor,
    ROUND(100.0 * (SELECT COUNT(*) FROM expiry_anchor)
                / (SELECT COUNT(*) FROM labels), 2) AS pct_matched;


SELECT '--- 3. one anchor per subscriber (must be 1 and 1) ---' AS check_name;

SELECT MIN(n) AS min_rows_per_msno, MAX(n) AS max_rows_per_msno
FROM (SELECT msno, COUNT(*) AS n FROM expiry_anchor GROUP BY msno);


SELECT '--- 4. leakage guard (both must be 0) ---' AS check_name;

SELECT
    SUM(CASE WHEN anchor_transaction_date > expiry_date THEN 1 ELSE 0 END)
        AS anchor_dated_after_expiry,
    SUM(CASE WHEN expiry_date NOT BETWEEN 20170301 AND 20170331 THEN 1 ELSE 0 END)
        AS expiry_outside_march;


SELECT '--- 5. window boundaries (expect exactly 30 and 56) ---' AS check_name;

SELECT
    MIN(julianday(expiry_date_iso)
        - julianday(date(substr(CAST(window30_start AS TEXT), 1, 4) || '-' ||
                         substr(CAST(window30_start AS TEXT), 5, 2) || '-' ||
                         substr(CAST(window30_start AS TEXT), 7, 2)))) AS min_days_30,
    MAX(julianday(expiry_date_iso)
        - julianday(date(substr(CAST(window56_start AS TEXT), 1, 4) || '-' ||
                         substr(CAST(window56_start AS TEXT), 5, 2) || '-' ||
                         substr(CAST(window56_start AS TEXT), 7, 2)))) AS max_days_56;


SELECT '--- 6. cancellation context ---' AS check_name;

SELECT
    SUM(anchor_is_cancel)        AS anchors_that_are_cancellations,
    SUM(cancel_on_anchor_date)   AS purchase_preferred_over_same_day_cancel,
    SUM(cancel_before_expiry)    AS subscribers_with_any_cancellation,
    COUNT(*)                     AS total
FROM expiry_anchor;
