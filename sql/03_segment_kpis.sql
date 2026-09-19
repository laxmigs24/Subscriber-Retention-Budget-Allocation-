-- ============================================================================
-- 03_segment_kpis.sql
--
-- Purpose : Build the account-level segmentation dimensions, assemble the
--           single analysis table everything downstream reads, and expose
--           renewal-rate rollups for the dashboard.
--
-- Inputs  : expiry_anchor, tx_clean, members, labels,
--           features_behaviour_30d, features_engagement_trend
-- Outputs : features_account, analysis_base, v_kpi_by_segment
--
-- Run     : sqlite3 data/kkbox.db < sql/03_segment_kpis.sql
--
-- Band labels are number-prefixed ('02 monthly') so that alphabetical sorting
-- in Tableau matches logical order without a custom sort on every sheet.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Account-level features and segmentation dimensions
--
-- Prior history is counted strictly BEFORE the anchor transaction, never up to
-- expiry. Counting to expiry would include the anchor itself and, worse, would
-- differ between subscribers depending on how close their purchase sat to
-- their expiry date.
-- ----------------------------------------------------------------------------

DROP TABLE IF EXISTS features_account;

CREATE TABLE features_account AS
WITH prior_history AS (
    SELECT
        a.msno,
        COUNT(*)                                          AS prior_tx_count,
        SUM(t.is_cancel)                                  AS prior_cancel_count,
        COUNT(DISTINCT t.payment_plan_days)               AS prior_distinct_plans,
        SUM(CASE WHEN t.actual_amount_paid < t.plan_list_price THEN 1 ELSE 0 END)
                                                          AS prior_discounted_tx,
        MIN(t.transaction_date)                           AS first_tx_date
    FROM expiry_anchor a
    JOIN tx_clean      t
      ON t.msno             =  a.msno
     AND t.transaction_date <  a.anchor_transaction_date
    GROUP BY a.msno
)

SELECT
    a.msno,

    -- ---------- tenure ----------
    CAST(julianday(a.expiry_date_iso)
         - julianday(date(substr(CAST(m.registration_date AS TEXT), 1, 4) || '-' ||
                          substr(CAST(m.registration_date AS TEXT), 5, 2) || '-' ||
                          substr(CAST(m.registration_date AS TEXT), 7, 2)))
    AS INTEGER)                                           AS tenure_days,

    ROUND((julianday(a.expiry_date_iso)
           - julianday(date(substr(CAST(m.registration_date AS TEXT), 1, 4) || '-' ||
                            substr(CAST(m.registration_date AS TEXT), 5, 2) || '-' ||
                            substr(CAST(m.registration_date AS TEXT), 7, 2)))) / 30.44, 2)
                                                          AS tenure_months,

    CASE
        WHEN m.registration_date IS NULL THEN '99 unknown'
        WHEN (julianday(a.expiry_date_iso)
              - julianday(date(substr(CAST(m.registration_date AS TEXT), 1, 4) || '-' ||
                               substr(CAST(m.registration_date AS TEXT), 5, 2) || '-' ||
                               substr(CAST(m.registration_date AS TEXT), 7, 2)))) / 30.44 < 3  THEN '01 0-3 months'
        WHEN (julianday(a.expiry_date_iso)
              - julianday(date(substr(CAST(m.registration_date AS TEXT), 1, 4) || '-' ||
                               substr(CAST(m.registration_date AS TEXT), 5, 2) || '-' ||
                               substr(CAST(m.registration_date AS TEXT), 7, 2)))) / 30.44 < 6  THEN '02 3-6 months'
        WHEN (julianday(a.expiry_date_iso)
              - julianday(date(substr(CAST(m.registration_date AS TEXT), 1, 4) || '-' ||
                               substr(CAST(m.registration_date AS TEXT), 5, 2) || '-' ||
                               substr(CAST(m.registration_date AS TEXT), 7, 2)))) / 30.44 < 12 THEN '03 6-12 months'
        WHEN (julianday(a.expiry_date_iso)
              - julianday(date(substr(CAST(m.registration_date AS TEXT), 1, 4) || '-' ||
                               substr(CAST(m.registration_date AS TEXT), 5, 2) || '-' ||
                               substr(CAST(m.registration_date AS TEXT), 7, 2)))) / 30.44 < 24 THEN '04 1-2 years'
        ELSE '05 2+ years'
    END                                                   AS tenure_band,

    -- ---------- plan ----------
    a.payment_plan_days,
    CASE
        WHEN a.payment_plan_days <=   7 THEN '01 weekly or less'
        WHEN a.payment_plan_days <=  31 THEN '02 monthly'
        WHEN a.payment_plan_days <= 100 THEN '03 quarterly'
        WHEN a.payment_plan_days <= 200 THEN '04 half-year'
        ELSE                                 '05 annual or longer'
    END                                                   AS plan_band,

    a.payment_method_id,
    a.is_auto_renew,
    a.cancel_before_expiry,

    -- ---------- money ----------
    a.plan_list_price,
    a.actual_amount_paid,

    -- ARPU normalised to a 30-day month so 7-, 30- and 180-day plans compare.
    CASE WHEN a.payment_plan_days > 0
         THEN ROUND(1.0 * a.actual_amount_paid / a.payment_plan_days * 30.0, 2)
    END                                                   AS monthly_arpu_ntd,

    CASE WHEN a.payment_plan_days > 0
         THEN ROUND(1.0 * a.actual_amount_paid / a.payment_plan_days * 30.0 / 34.0, 2)
    END                                                   AS monthly_arpu_eur,

    CASE WHEN a.plan_list_price > 0
         THEN ROUND(1.0 * (a.plan_list_price - a.actual_amount_paid) / a.plan_list_price, 4)
    END                                                   AS discount_depth,

    CASE
        WHEN a.plan_list_price <= 0                              THEN '99 free or anomalous'
        WHEN a.actual_amount_paid >  a.plan_list_price           THEN '98 paid above list'
        WHEN a.actual_amount_paid =  a.plan_list_price           THEN '00 no discount'
        WHEN 1.0 * (a.plan_list_price - a.actual_amount_paid)
                 / a.plan_list_price < 0.10                      THEN '01 light (<10%)'
        WHEN 1.0 * (a.plan_list_price - a.actual_amount_paid)
                 / a.plan_list_price < 0.30                      THEN '02 moderate (10-30%)'
        ELSE                                                          '03 deep (30%+)'
    END                                                   AS discount_band,

    -- ---------- prior behaviour ----------
    COALESCE(h.prior_tx_count,      0)                    AS prior_tx_count,
    COALESCE(h.prior_cancel_count,  0)                    AS prior_cancel_count,
    COALESCE(h.prior_discounted_tx, 0)                    AS prior_discounted_tx,
    COALESCE(h.prior_distinct_plans, 0)                   AS prior_distinct_plans,

    -- ---------- demographics ----------
    m.city,
    m.registered_via,
    COALESCE(m.gender, 'unstated')                        AS gender,

    -- Age rule from the audit: outside 13-100 is unreliable, so it is nulled
    -- rather than dropped, and whether it was stated is kept as its own signal.
    CASE WHEN m.bd BETWEEN 13 AND 100 THEN m.bd END       AS age,
    CASE WHEN m.bd BETWEEN 13 AND 100 THEN 1 ELSE 0 END   AS age_stated

FROM expiry_anchor       a
LEFT JOIN members        m ON m.msno = a.msno
LEFT JOIN prior_history  h ON h.msno = a.msno;

CREATE UNIQUE INDEX idx_account_msno ON features_account (msno);


-- ----------------------------------------------------------------------------
-- 2. The analysis base
--
-- One row per cohort subscriber. This is the only table the notebooks, the
-- dashboard extract and the model should read. Keeping a single source means
-- a metric cannot quietly differ between the deck and the model.
-- ----------------------------------------------------------------------------

DROP TABLE IF EXISTS analysis_base;

CREATE TABLE analysis_base AS
SELECT
    l.msno,
    l.is_churn,

    e.expiry_date,
    e.expiry_date_iso,
    e.anchor_transaction_date,

    f.tenure_days, f.tenure_months, f.tenure_band,
    f.payment_plan_days, f.plan_band,
    f.payment_method_id, f.is_auto_renew, f.cancel_before_expiry,
    f.plan_list_price, f.actual_amount_paid,
    f.monthly_arpu_ntd, f.monthly_arpu_eur,
    f.discount_depth, f.discount_band,
    f.prior_tx_count, f.prior_cancel_count,
    f.prior_discounted_tx, f.prior_distinct_plans,
    f.city, f.registered_via, f.gender, f.age, f.age_stated,

    b.has_logs_30d,
    b.active_days_30d, b.active_day_rate_30d,
    b.total_hours_30d, b.unique_tracks_30d,
    b.plays_total_30d, b.plays_100_30d,
    b.completion_ratio_30d, b.skip_ratio_30d,
    b.mins_per_active_day_30d, b.days_since_last_play,

    t.recent_active_days, t.baseline_active_days,
    t.active_day_trend_ratio, t.hours_trend_ratio,
    t.engagement_trend

FROM labels                     l
JOIN expiry_anchor              e ON e.msno = l.msno
LEFT JOIN features_account      f ON f.msno = l.msno
LEFT JOIN features_behaviour_30d b ON b.msno = l.msno
LEFT JOIN features_engagement_trend t ON t.msno = l.msno;

CREATE UNIQUE INDEX idx_base_msno   ON analysis_base (msno);
CREATE INDEX        idx_base_churn  ON analysis_base (is_churn);
CREATE INDEX        idx_base_tenure ON analysis_base (tenure_band);


-- ----------------------------------------------------------------------------
-- 3. Segment KPI view
--
-- Long format, one row per dimension value, so a single Tableau extract can
-- drive several sheets without re-aggregating.
--
-- Both renewal rates are exposed. The value-weighted one is the primary KPI —
-- headcount treats a 7-day trial and a 180-day subscriber as equals, and the
-- budget decision is about revenue.
-- ----------------------------------------------------------------------------

DROP VIEW IF EXISTS v_kpi_by_segment;

CREATE VIEW v_kpi_by_segment AS
WITH unioned AS (
    SELECT 'tenure_band'    AS dimension, tenure_band    AS segment, is_churn, monthly_arpu_ntd FROM analysis_base
    UNION ALL
    SELECT 'plan_band',            plan_band,            is_churn, monthly_arpu_ntd FROM analysis_base
    UNION ALL
    SELECT 'discount_band',        discount_band,        is_churn, monthly_arpu_ntd FROM analysis_base
    UNION ALL
    SELECT 'engagement_trend',     engagement_trend,     is_churn, monthly_arpu_ntd FROM analysis_base
    UNION ALL
    SELECT 'auto_renew',
           CASE WHEN is_auto_renew = 1 THEN 'auto-renew on' ELSE 'auto-renew off' END,
           is_churn, monthly_arpu_ntd FROM analysis_base
    UNION ALL
    SELECT 'payment_method',       'method ' || CAST(payment_method_id AS TEXT),
           is_churn, monthly_arpu_ntd FROM analysis_base
)
SELECT
    dimension,
    segment,
    COUNT(*)                                                  AS subscribers,
    SUM(is_churn)                                             AS churned,

    ROUND(100.0 * (1 - 1.0 * SUM(is_churn) / COUNT(*)), 2)    AS renewal_rate_pct,

    ROUND(100.0 * (1 - SUM(is_churn * COALESCE(monthly_arpu_ntd, 0))
                       / NULLIF(SUM(COALESCE(monthly_arpu_ntd, 0)), 0)), 2)
                                                              AS renewal_rate_value_weighted_pct,

    ROUND(AVG(monthly_arpu_ntd), 2)                           AS avg_monthly_arpu_ntd,
    ROUND(SUM(monthly_arpu_ntd), 0)                           AS total_monthly_arpu_ntd,
    ROUND(SUM(is_churn * COALESCE(monthly_arpu_ntd, 0)), 0)   AS monthly_arpu_at_risk_ntd,

    CASE WHEN COUNT(*) < 500 THEN 1 ELSE 0 END                AS below_min_segment_size
FROM unioned
GROUP BY dimension, segment
ORDER BY dimension, segment;


-- ============================================================================
-- VALIDATION
-- ============================================================================

SELECT '--- 1. analysis_base coverage (rows must equal cohort with anchor) ---' AS check_name;

SELECT
    (SELECT COUNT(*) FROM labels)        AS cohort,
    (SELECT COUNT(*) FROM analysis_base) AS base_rows,
    (SELECT COUNT(*) FROM analysis_base WHERE monthly_arpu_ntd IS NULL) AS null_arpu,
    (SELECT COUNT(*) FROM analysis_base WHERE tenure_band = '99 unknown') AS unknown_tenure;


SELECT '--- 2. headline numbers — write these down ---' AS check_name;

SELECT
    COUNT(*)                                                  AS subscribers,
    ROUND(100.0 * AVG(is_churn), 3)                           AS churn_rate_pct,
    ROUND(100.0 * (1 - AVG(is_churn)), 3)                     AS renewal_rate_pct,
    ROUND(100.0 * (1 - SUM(is_churn * COALESCE(monthly_arpu_ntd, 0))
                       / NULLIF(SUM(COALESCE(monthly_arpu_ntd, 0)), 0)), 3)
                                                              AS renewal_rate_value_weighted_pct,
    ROUND(SUM(COALESCE(monthly_arpu_ntd, 0)) / 34.0, 0)       AS total_monthly_value_eur,
    ROUND(SUM(is_churn * COALESCE(monthly_arpu_ntd, 0)) / 34.0, 0) AS monthly_value_at_risk_eur
FROM analysis_base;


SELECT '--- 3. Q1 — churn vs value by tenure (the headline chart) ---' AS check_name;

SELECT
    tenure_band,
    COUNT(*)                                            AS subscribers,
    ROUND(100.0 * AVG(is_churn), 2)                     AS churn_rate_pct,
    ROUND(SUM(COALESCE(monthly_arpu_ntd, 0)) / 34.0, 0) AS segment_value_eur,
    ROUND(100.0 * SUM(COALESCE(monthly_arpu_ntd, 0))
          / (SELECT SUM(COALESCE(monthly_arpu_ntd, 0)) FROM analysis_base), 1)
                                                        AS pct_of_total_value
FROM analysis_base
GROUP BY tenure_band
ORDER BY tenure_band;


SELECT '--- 4. Q5 — the auto-renew assumption under test ---' AS check_name;

SELECT
    CASE WHEN is_auto_renew = 1 THEN 'auto-renew on' ELSE 'auto-renew off' END AS segment,
    COUNT(*)                                            AS subscribers,
    ROUND(100.0 * AVG(is_churn), 2)                     AS churn_rate_pct,
    ROUND(SUM(COALESCE(monthly_arpu_ntd, 0)) / 34.0, 0) AS segment_value_eur
FROM analysis_base
GROUP BY is_auto_renew;


SELECT '--- 5. segments below the 500-subscriber floor ---' AS check_name;

SELECT dimension, segment, subscribers
FROM v_kpi_by_segment
WHERE below_min_segment_size = 1
ORDER BY dimension, subscribers;
