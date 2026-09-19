-- ============================================================================
-- 02_expiry_anchored_window.sql
--
-- Purpose : Build listening behaviour features over a window anchored to each
--           subscriber's OWN expiry date, not a fixed calendar window.
--
-- Inputs  : user_logs, expiry_anchor, labels
-- Outputs : features_behaviour_30d
--           features_behaviour_weekly
--           features_engagement_trend
--
-- Run     : sqlite3 data/kkbox.db < sql/02_expiry_anchored_window.sql
--
-- LEAKAGE RULE, enforced in every join below:
--     log_date >= window_start  AND  log_date < expiry_date
-- Strictly before expiry. Activity on the expiry day itself is excluded,
-- because a renewal decision may already have been taken that day.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Thirty-day behavioural window
--
-- LEFT JOIN from expiry_anchor so that subscribers with no listening activity
-- appear as genuine zeros rather than vanishing. A silent drop here would bias
-- the analysis toward engaged users — exactly the wrong direction for churn.
-- ----------------------------------------------------------------------------

DROP TABLE IF EXISTS features_behaviour_30d;

CREATE TABLE features_behaviour_30d AS
WITH windowed AS (
    SELECT
        a.msno,
        l.log_date,
        l.num_25, l.num_50, l.num_75, l.num_985, l.num_100,
        l.num_unq,
        l.total_secs
    FROM expiry_anchor a
    JOIN user_logs     l
      ON l.msno      =  a.msno
     AND l.log_date  >= a.window30_start
     AND l.log_date  <  a.expiry_date
),

agg AS (
    SELECT
        msno,
        COUNT(DISTINCT log_date)                      AS active_days_30d,
        MAX(log_date)                                 AS last_active_date,
        SUM(total_secs)                               AS total_secs_30d,
        SUM(num_unq)                                  AS unique_tracks_30d,
        SUM(num_25)                                   AS plays_25_30d,
        SUM(num_50)                                   AS plays_50_30d,
        SUM(num_75)                                   AS plays_75_30d,
        SUM(num_985)                                  AS plays_985_30d,
        SUM(num_100)                                  AS plays_100_30d,
        SUM(num_25 + num_50 + num_75 + num_985 + num_100) AS plays_total_30d
    FROM windowed
    GROUP BY msno
)

SELECT
    a.msno,
    CASE WHEN g.msno IS NULL THEN 0 ELSE 1 END        AS has_logs_30d,

    COALESCE(g.active_days_30d,   0)                  AS active_days_30d,
    ROUND(COALESCE(g.active_days_30d, 0) / 30.0, 4)   AS active_day_rate_30d,

    ROUND(COALESCE(g.total_secs_30d, 0), 1)           AS total_secs_30d,
    ROUND(COALESCE(g.total_secs_30d, 0) / 3600.0, 2)  AS total_hours_30d,

    COALESCE(g.unique_tracks_30d, 0)                  AS unique_tracks_30d,
    COALESCE(g.plays_total_30d,   0)                  AS plays_total_30d,
    COALESCE(g.plays_100_30d,     0)                  AS plays_100_30d,
    COALESCE(g.plays_25_30d,      0)                  AS plays_25_30d,

    -- Engagement QUALITY: share of tracks played to completion.
    -- Null, not zero, when there were no plays at all — "did not listen" and
    -- "listened but skipped everything" are different states and must not be
    -- collapsed into the same number.
    CASE WHEN COALESCE(g.plays_total_30d, 0) > 0
         THEN ROUND(1.0 * g.plays_100_30d / g.plays_total_30d, 4)
    END                                               AS completion_ratio_30d,

    CASE WHEN COALESCE(g.plays_total_30d, 0) > 0
         THEN ROUND(1.0 * g.plays_25_30d / g.plays_total_30d, 4)
    END                                               AS skip_ratio_30d,

    -- Intensity per day actually used, rather than per calendar day
    CASE WHEN COALESCE(g.active_days_30d, 0) > 0
         THEN ROUND(g.total_secs_30d / g.active_days_30d / 60.0, 1)
    END                                               AS mins_per_active_day_30d,

    -- Recency. Null when the subscriber never listened in the window.
    CASE WHEN g.last_active_date IS NOT NULL
         THEN CAST(julianday(a.expiry_date_iso)
                   - julianday(date(substr(CAST(g.last_active_date AS TEXT), 1, 4) || '-' ||
                                    substr(CAST(g.last_active_date AS TEXT), 5, 2) || '-' ||
                                    substr(CAST(g.last_active_date AS TEXT), 7, 2)))
              AS INTEGER)
    END                                               AS days_since_last_play

FROM expiry_anchor a
LEFT JOIN agg      g ON g.msno = a.msno;

CREATE UNIQUE INDEX idx_beh30_msno ON features_behaviour_30d (msno);


-- ----------------------------------------------------------------------------
-- 2. Weekly aggregates across the eight weeks before expiry
--
-- week_index 1 = the 7 days immediately before expiry
-- week_index 8 = days 50-56 before expiry
--
-- Long format, one row per subscriber per week. This feeds the engagement
-- decay chart (dashboard visual 4) and answers Q2: how early is the signal
-- visible?
--
-- The integer BETWEEN prunes the log table first; julianday() then runs only
-- on rows that survived, which keeps this affordable.
-- ----------------------------------------------------------------------------

DROP TABLE IF EXISTS features_behaviour_weekly;

CREATE TABLE features_behaviour_weekly AS
WITH windowed AS (
    SELECT
        a.msno,
        CAST(julianday(a.expiry_date_iso)
             - julianday(date(substr(CAST(l.log_date AS TEXT), 1, 4) || '-' ||
                              substr(CAST(l.log_date AS TEXT), 5, 2) || '-' ||
                              substr(CAST(l.log_date AS TEXT), 7, 2)))
        AS INTEGER)                                   AS days_before_expiry,
        l.log_date,
        l.num_25, l.num_100, l.num_50, l.num_75, l.num_985,
        l.num_unq,
        l.total_secs
    FROM expiry_anchor a
    JOIN user_logs     l
      ON l.msno      =  a.msno
     AND l.log_date  >= a.window56_start
     AND l.log_date  <  a.expiry_date
),

weeks AS (
    SELECT
        msno,
        ((days_before_expiry - 1) / 7) + 1            AS week_index,
        log_date,
        num_25, num_50, num_75, num_985, num_100,
        num_unq,
        total_secs
    FROM windowed
    WHERE days_before_expiry BETWEEN 1 AND 56
)

SELECT
    w.msno,
    w.week_index,
    l.is_churn,
    COUNT(DISTINCT w.log_date)                        AS active_days,
    ROUND(SUM(w.total_secs) / 3600.0, 3)              AS hours,
    SUM(w.num_unq)                                    AS unique_tracks,
    SUM(w.num_25 + w.num_50 + w.num_75 + w.num_985 + w.num_100) AS plays_total,
    SUM(w.num_100)                                    AS plays_100,
    CASE WHEN SUM(w.num_25 + w.num_50 + w.num_75 + w.num_985 + w.num_100) > 0
         THEN ROUND(1.0 * SUM(w.num_100)
                    / SUM(w.num_25 + w.num_50 + w.num_75 + w.num_985 + w.num_100), 4)
    END                                               AS completion_ratio
FROM weeks  w
JOIN labels l ON l.msno = w.msno
GROUP BY w.msno, w.week_index, l.is_churn;

CREATE INDEX idx_behweek_msno ON features_behaviour_weekly (msno, week_index);
CREATE INDEX idx_behweek_week ON features_behaviour_weekly (week_index);


-- ----------------------------------------------------------------------------
-- 3. Engagement trend
--
-- Compares the most recent fortnight (weeks 1-2) against the fortnight four to
-- eight weeks out (weeks 5-8). This is the "is this subscriber cooling off"
-- feature, and it is the one with genuine operational lead time: it can be
-- computed a month before expiry, which is when CRM would need it.
-- ----------------------------------------------------------------------------

DROP TABLE IF EXISTS features_engagement_trend;

CREATE TABLE features_engagement_trend AS
WITH pivoted AS (
    SELECT
        msno,
        SUM(CASE WHEN week_index BETWEEN 1 AND 2 THEN active_days ELSE 0 END) AS recent_active_days,
        SUM(CASE WHEN week_index BETWEEN 5 AND 8 THEN active_days ELSE 0 END) AS baseline_active_days,
        SUM(CASE WHEN week_index BETWEEN 1 AND 2 THEN hours       ELSE 0 END) AS recent_hours,
        SUM(CASE WHEN week_index BETWEEN 5 AND 8 THEN hours       ELSE 0 END) AS baseline_hours
    FROM features_behaviour_weekly
    GROUP BY msno
)

SELECT
    a.msno,
    COALESCE(p.recent_active_days,   0)               AS recent_active_days,
    COALESCE(p.baseline_active_days, 0)               AS baseline_active_days,
    ROUND(COALESCE(p.recent_hours,   0), 3)           AS recent_hours,
    ROUND(COALESCE(p.baseline_hours, 0), 3)           AS baseline_hours,

    -- Baseline is a 4-week span and recent is a 2-week span, so the baseline is
    -- halved to put both on a per-fortnight footing before comparing.
    CASE WHEN COALESCE(p.baseline_active_days, 0) > 0
         THEN ROUND(1.0 * p.recent_active_days / (p.baseline_active_days / 2.0), 4)
    END                                               AS active_day_trend_ratio,

    CASE WHEN COALESCE(p.baseline_hours, 0) > 0
         THEN ROUND(p.recent_hours / (p.baseline_hours / 2.0), 4)
    END                                               AS hours_trend_ratio,

    CASE
        WHEN COALESCE(p.baseline_active_days, 0) = 0
             AND COALESCE(p.recent_active_days, 0) = 0 THEN 'never active'
        WHEN COALESCE(p.baseline_active_days, 0) = 0   THEN 'newly active'
        WHEN 1.0 * p.recent_active_days / (p.baseline_active_days / 2.0) < 0.5  THEN 'sharp decline'
        WHEN 1.0 * p.recent_active_days / (p.baseline_active_days / 2.0) < 0.85 THEN 'declining'
        WHEN 1.0 * p.recent_active_days / (p.baseline_active_days / 2.0) < 1.15 THEN 'stable'
        ELSE 'increasing'
    END                                               AS engagement_trend

FROM expiry_anchor a
LEFT JOIN pivoted  p ON p.msno = a.msno;

CREATE UNIQUE INDEX idx_trend_msno ON features_engagement_trend (msno);


-- ============================================================================
-- VALIDATION
-- ============================================================================

SELECT '--- 1. coverage (every anchored subscriber must have a row) ---' AS check_name;

SELECT
    (SELECT COUNT(*) FROM expiry_anchor)                 AS anchored,
    (SELECT COUNT(*) FROM features_behaviour_30d)        AS behaviour_rows,
    (SELECT SUM(has_logs_30d) FROM features_behaviour_30d) AS with_any_listening,
    (SELECT COUNT(*) FROM features_behaviour_30d WHERE has_logs_30d = 0) AS silent_subscribers;


SELECT '--- 2. bounds (all must be within range, no nulls in required fields) ---' AS check_name;

SELECT
    MIN(active_days_30d)      AS min_active_days,
    MAX(active_days_30d)      AS max_active_days,   -- must be <= 30
    MIN(completion_ratio_30d) AS min_completion,    -- must be >= 0
    MAX(completion_ratio_30d) AS max_completion,    -- must be <= 1
    MIN(days_since_last_play) AS min_recency,       -- must be >= 1
    MAX(days_since_last_play) AS max_recency        -- must be <= 30
FROM features_behaviour_30d;


SELECT '--- 3. weekly index range (must be 1 to 8) ---' AS check_name;

SELECT MIN(week_index) AS min_week, MAX(week_index) AS max_week,
       COUNT(*) AS rows_total
FROM features_behaviour_weekly;


SELECT '--- 4. THE DECAY CURVE — Q2 answered here ---' AS check_name;

SELECT
    week_index,
    ROUND(AVG(CASE WHEN is_churn = 0 THEN active_days END), 3) AS renewers_active_days,
    ROUND(AVG(CASE WHEN is_churn = 1 THEN active_days END), 3) AS churners_active_days,
    ROUND(AVG(CASE WHEN is_churn = 0 THEN completion_ratio END), 4) AS renewers_completion,
    ROUND(AVG(CASE WHEN is_churn = 1 THEN completion_ratio END), 4) AS churners_completion
FROM features_behaviour_weekly
GROUP BY week_index
ORDER BY week_index;


SELECT '--- 5. trend distribution ---' AS check_name;

SELECT
    t.engagement_trend,
    COUNT(*)                                    AS subscribers,
    ROUND(100.0 * AVG(l.is_churn), 2)           AS churn_rate_pct
FROM features_engagement_trend t
JOIN labels l ON l.msno = t.msno
GROUP BY t.engagement_trend
ORDER BY churn_rate_pct DESC;
