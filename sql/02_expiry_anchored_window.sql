-- ============================================================================
-- 02_expiry_anchored_window.sql   (v2 — week spine fix)
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
-- ---------------------------------------------------------------------------
-- WHAT CHANGED IN v2, AND WHY IT MATTERED
--
-- v1 built the weekly table by aggregating log rows. A subscriber who did not
-- listen at all in a given week produced no log rows, so produced no weekly
-- row, so was silently dropped from that week's average.
--
-- The resulting statistic was "average active days among subscribers who were
-- active" — truncated by construction, and therefore almost flat. It showed
-- churners and renewers both sitting near 4.5 active days in every one of the
-- eight weeks, with a Cohen's d that never left the negligible band. That read
-- as "there is no behavioural signal". It was an artefact of the join.
--
-- v2 builds a SPINE first: every subscriber crossed with all eight weeks. The
-- aggregates are LEFT JOINed onto it, so missing weeks become genuine zeros.
-- Going quiet is now counted as going quiet.
--
-- completion_ratio deliberately stays NULL on a silent week. "Did not listen"
-- and "listened but skipped everything" are different states; averaging a zero
-- into the ratio would conflate them. Volume metrics get zeros, quality
-- metrics get nulls.
-- ---------------------------------------------------------------------------
--
-- LEAKAGE RULE, enforced in every join below:
--     log_date >= window_start  AND  log_date < expiry_date
-- Strictly before expiry. Activity on the expiry day itself is excluded,
-- because a renewal decision may already have been taken that day.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Thirty-day behavioural window
--
-- LEFT JOIN from expiry_anchor so subscribers with no listening activity appear
-- as genuine zeros rather than vanishing. This table was already correct in v1;
-- the spine bug affected only the weekly table.
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
        COUNT(DISTINCT log_date)                          AS active_days_30d,
        MAX(log_date)                                     AS last_active_date,
        SUM(total_secs)                                   AS total_secs_30d,
        SUM(num_unq)                                      AS unique_tracks_30d,
        SUM(num_25)                                       AS plays_25_30d,
        SUM(num_100)                                      AS plays_100_30d,
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

    CASE WHEN COALESCE(g.plays_total_30d, 0) > 0
         THEN ROUND(1.0 * g.plays_100_30d / g.plays_total_30d, 4)
    END                                               AS completion_ratio_30d,

    CASE WHEN COALESCE(g.plays_total_30d, 0) > 0
         THEN ROUND(1.0 * g.plays_25_30d / g.plays_total_30d, 4)
    END                                               AS skip_ratio_30d,

    CASE WHEN COALESCE(g.active_days_30d, 0) > 0
         THEN ROUND(g.total_secs_30d / g.active_days_30d / 60.0, 1)
    END                                               AS mins_per_active_day_30d,

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
-- 2. Weekly aggregates across the eight weeks before expiry — SPINE VERSION
--
-- week_index 1 = the 7 days immediately before expiry
-- week_index 8 = days 50-56 before expiry
--
-- Every subscriber gets exactly 8 rows. Weeks with no listening carry zeros for
-- volume and NULL for quality. This is what makes the decay curve honest: a
-- subscriber who stops listening in week 2 now drags the week-2 average down,
-- instead of quietly leaving the calculation.
-- ----------------------------------------------------------------------------

DROP TABLE IF EXISTS features_behaviour_weekly;

CREATE TABLE features_behaviour_weekly AS
WITH RECURSIVE
week_numbers(week_index) AS (
    SELECT 1
    UNION ALL
    SELECT week_index + 1 FROM week_numbers WHERE week_index < 8
),

-- one row per subscriber per week, before any data is attached
spine AS (
    SELECT a.msno, w.week_index
    FROM expiry_anchor a
    CROSS JOIN week_numbers w
),

windowed AS (
    SELECT
        a.msno,
        CAST(julianday(a.expiry_date_iso)
             - julianday(date(substr(CAST(l.log_date AS TEXT), 1, 4) || '-' ||
                              substr(CAST(l.log_date AS TEXT), 5, 2) || '-' ||
                              substr(CAST(l.log_date AS TEXT), 7, 2)))
        AS INTEGER)                                   AS days_before_expiry,
        l.log_date,
        l.num_25, l.num_50, l.num_75, l.num_985, l.num_100,
        l.num_unq,
        l.total_secs
    FROM expiry_anchor a
    JOIN user_logs     l
      ON l.msno      =  a.msno
     AND l.log_date  >= a.window56_start
     AND l.log_date  <  a.expiry_date
),

weekly_agg AS (
    SELECT
        msno,
        ((days_before_expiry - 1) / 7) + 1                AS week_index,
        COUNT(DISTINCT log_date)                          AS active_days,
        SUM(total_secs)                                   AS total_secs,
        SUM(num_unq)                                      AS unique_tracks,
        SUM(num_100)                                      AS plays_100,
        SUM(num_25 + num_50 + num_75 + num_985 + num_100) AS plays_total
    FROM windowed
    WHERE days_before_expiry BETWEEN 1 AND 56
    GROUP BY msno, ((days_before_expiry - 1) / 7) + 1
)

SELECT
    s.msno,
    s.week_index,
    l.is_churn,

    -- volume: silence is zero, not missing
    COALESCE(g.active_days,   0)                      AS active_days,
    ROUND(COALESCE(g.total_secs, 0) / 3600.0, 3)      AS hours,
    COALESCE(g.unique_tracks, 0)                      AS unique_tracks,
    COALESCE(g.plays_total,   0)                      AS plays_total,
    COALESCE(g.plays_100,     0)                      AS plays_100,

    -- quality: undefined when nothing was played, so NULL
    CASE WHEN COALESCE(g.plays_total, 0) > 0
         THEN ROUND(1.0 * g.plays_100 / g.plays_total, 4)
    END                                               AS completion_ratio,

    CASE WHEN g.msno IS NULL THEN 0 ELSE 1 END        AS was_active

FROM spine  s
JOIN labels l ON l.msno = s.msno
LEFT JOIN weekly_agg g
       ON g.msno       = s.msno
      AND g.week_index = s.week_index;

CREATE INDEX idx_behweek_msno ON features_behaviour_weekly (msno, week_index);
CREATE INDEX idx_behweek_week ON features_behaviour_weekly (week_index);


-- ----------------------------------------------------------------------------
-- 3. Engagement trend
--
-- Compares the most recent fortnight (weeks 1-2) against the fortnight four to
-- eight weeks out (weeks 5-8). With the spine in place this measures real
-- decline rather than decline among the still-active.
--
-- This is the feature with genuine operational lead time: computable a month
-- before expiry, which is when CRM would need it.
-- ----------------------------------------------------------------------------

DROP TABLE IF EXISTS features_engagement_trend;

CREATE TABLE features_engagement_trend AS
WITH pivoted AS (
    SELECT
        msno,
        SUM(CASE WHEN week_index BETWEEN 1 AND 2 THEN active_days ELSE 0 END) AS recent_active_days,
        SUM(CASE WHEN week_index BETWEEN 5 AND 8 THEN active_days ELSE 0 END) AS baseline_active_days,
        SUM(CASE WHEN week_index BETWEEN 1 AND 2 THEN hours       ELSE 0 END) AS recent_hours,
        SUM(CASE WHEN week_index BETWEEN 5 AND 8 THEN hours       ELSE 0 END) AS baseline_hours,
        SUM(CASE WHEN week_index BETWEEN 1 AND 2 THEN was_active  ELSE 0 END) AS recent_active_weeks,
        SUM(CASE WHEN week_index BETWEEN 5 AND 8 THEN was_active  ELSE 0 END) AS baseline_active_weeks
    FROM features_behaviour_weekly
    GROUP BY msno
)

SELECT
    a.msno,
    COALESCE(p.recent_active_days,    0)              AS recent_active_days,
    COALESCE(p.baseline_active_days,  0)              AS baseline_active_days,
    ROUND(COALESCE(p.recent_hours,    0), 3)          AS recent_hours,
    ROUND(COALESCE(p.baseline_hours,  0), 3)          AS baseline_hours,
    COALESCE(p.recent_active_weeks,   0)              AS recent_active_weeks,
    COALESCE(p.baseline_active_weeks, 0)              AS baseline_active_weeks,

    -- Baseline spans 4 weeks and recent spans 2, so the baseline is halved to
    -- put both on a per-fortnight footing before comparing.
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
        WHEN COALESCE(p.recent_active_days,   0) = 0   THEN 'went silent'
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

SELECT '--- 1. spine integrity: every subscriber must have exactly 8 weeks ---' AS check_name;

SELECT
    (SELECT COUNT(*) FROM expiry_anchor)                     AS anchored,
    (SELECT COUNT(*) FROM features_behaviour_weekly)         AS weekly_rows,
    (SELECT COUNT(*) FROM expiry_anchor) * 8                 AS expected_rows,
    (SELECT MIN(n) FROM (SELECT msno, COUNT(*) n
                         FROM features_behaviour_weekly GROUP BY msno)) AS min_weeks,
    (SELECT MAX(n) FROM (SELECT msno, COUNT(*) n
                         FROM features_behaviour_weekly GROUP BY msno)) AS max_weeks;


SELECT '--- 2. THE BUG, MADE VISIBLE ---' AS check_name;

-- Left column reproduces the v1 statistic (conditioned on activity).
-- Right column is the honest one. The difference is the artefact.
SELECT
    week_index,
    ROUND(AVG(CASE WHEN was_active = 1 THEN active_days END), 3) AS v1_active_only,
    ROUND(AVG(active_days), 3)                                   AS v2_all_subscribers,
    ROUND(100.0 * AVG(was_active), 1)                            AS pct_active_that_week
FROM features_behaviour_weekly
GROUP BY week_index
ORDER BY week_index;


SELECT '--- 3. THE DECAY CURVE — Q2 answered here ---' AS check_name;

SELECT
    week_index,
    ROUND(AVG(CASE WHEN is_churn = 0 THEN active_days END), 3) AS renewers_active_days,
    ROUND(AVG(CASE WHEN is_churn = 1 THEN active_days END), 3) AS churners_active_days,
    ROUND(AVG(CASE WHEN is_churn = 0 THEN active_days END)
          - AVG(CASE WHEN is_churn = 1 THEN active_days END), 3) AS gap,
    ROUND(100.0 * AVG(CASE WHEN is_churn = 0 THEN was_active END), 1) AS pct_renewers_active,
    ROUND(100.0 * AVG(CASE WHEN is_churn = 1 THEN was_active END), 1) AS pct_churners_active
FROM features_behaviour_weekly
GROUP BY week_index
ORDER BY week_index;


SELECT '--- 4. trend distribution and churn by trend ---' AS check_name;

SELECT
    t.engagement_trend,
    COUNT(*)                                    AS subscribers,
    ROUND(100.0 * AVG(l.is_churn), 2)           AS churn_rate_pct
FROM features_engagement_trend t
JOIN labels l ON l.msno = t.msno
GROUP BY t.engagement_trend
ORDER BY churn_rate_pct DESC;


SELECT '--- 5. 30-day table bounds (unchanged from v1, re-checked) ---' AS check_name;

SELECT
    MAX(active_days_30d)      AS max_active_days,   -- must be <= 30
    MIN(completion_ratio_30d) AS min_completion,    -- must be >= 0
    MAX(completion_ratio_30d) AS max_completion,    -- must be <= 1
    MIN(days_since_last_play) AS min_recency,       -- must be >= 1
    MAX(days_since_last_play) AS max_recency        -- must be <= 30
FROM features_behaviour_30d;
