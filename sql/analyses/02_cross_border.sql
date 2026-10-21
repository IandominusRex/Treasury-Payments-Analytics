-- =====================================================================================
-- 02 · Cross-border payments
-- =====================================================================================
-- Question : where does money go across borders, how, how long does it take, how often does it fail?
-- Metrics  : average and 90th-percentile hours to settle; failure rate by corridor and rail.
-- Chart    : corridor scorecard table with conditional formatting (red = slow / failing).
-- So what  : which corridors deserve a different rail or bank.
-- Tables   : fact_payment, dim_payment_type
-- =====================================================================================


-- -------------------------------------------------------------------------------------
-- Step 1 · Cross-border payments with settlement time in hours and a failure flag
-- -------------------------------------------------------------------------------------
--   * pending excluded: not settled, not failed, yet - it would distort both metrics
--   * hours_to_settle only for successful payments (failed ones never settled)
--   * julianday() turns the text timestamp into a day number; x 24 = hours
WITH xb AS (
    SELECT p.payment_id,
           p.sender_country || ' -> ' || p.receiver_country AS corridor,
           t.rail,
           p.amount_sgd,
           p.status,
           CASE WHEN p.status IN ('rejected', 'returned') THEN 1 ELSE 0 END AS is_failed,
           CASE WHEN p.status IN ('completed', 'delayed')
                THEN (julianday(p.settled_ts) - julianday(p.initiated_ts)) * 24 END AS hours_to_settle
    FROM fact_payment p
    JOIN dim_payment_type t ON t.type_id = p.type_id
    WHERE p.is_intercompany = 0
      AND p.sender_country <> p.receiver_country
      AND p.status <> 'pending'
)
SELECT * FROM xb LIMIT 20;


-- -------------------------------------------------------------------------------------
-- Step 2 · Percentiles in SQLite with the rank trick
-- -------------------------------------------------------------------------------------
-- SQLite has no PERCENTILE_CONT. So:
--   1. number each payment within its corridor, fastest first  (ROW_NUMBER)
--   2. count payments per corridor                              (COUNT(*) OVER)
--   3. P50 = the row at position 0.5 x count; P90 = at 0.9 x count
-- Study this one carefully - you'll reuse it in analysis 03.
WITH xb AS (
    SELECT p.sender_country || ' -> ' || p.receiver_country AS corridor,
           (julianday(p.settled_ts) - julianday(p.initiated_ts)) * 24 AS hours_to_settle
    FROM fact_payment p
    WHERE p.is_intercompany = 0
      AND p.sender_country <> p.receiver_country
      AND p.status IN ('completed', 'delayed')
),
ranked AS (
    SELECT corridor, hours_to_settle,
           ROW_NUMBER() OVER (PARTITION BY corridor ORDER BY hours_to_settle) AS rn,
           COUNT(*)     OVER (PARTITION BY corridor)                          AS n
    FROM xb
)
SELECT corridor,
       n,
       ROUND(MAX(CASE WHEN rn = CAST(0.5 * n AS INTEGER) + 1 THEN hours_to_settle END), 1) AS p50_hours,
       ROUND(MAX(CASE WHEN rn = CAST(0.9 * n AS INTEGER) + 1 THEN hours_to_settle END), 1) AS p90_hours
FROM ranked
GROUP BY corridor, n
HAVING n >= 200            -- small corridors give noisy percentiles
ORDER BY p90_hours DESC;


-- -------------------------------------------------------------------------------------
-- Step 3 · Views
-- -------------------------------------------------------------------------------------
-- vw_02_corridor_scorecard   one row per corridor (>= 200 payments): volume, value, speed, failures
-- (A rail scorecard was dropped: cross-border payments use only 2 rails, so it had 2 rows.
--  Rails are compared in vw_03_rail_timing and vw_04_failure_rail.)

DROP VIEW IF EXISTS vw_02_corridor_scorecard;
CREATE VIEW vw_02_corridor_scorecard AS
WITH xb AS (
    SELECT p.sender_country || ' -> ' || p.receiver_country AS corridor,
           p.sender_country,
           p.receiver_country,
           p.amount_sgd,
           (julianday(p.settled_ts) - julianday(p.initiated_ts)) * 24 AS hours_to_settle,
           CASE WHEN p.status IN ('rejected', 'returned') THEN 1 ELSE 0 END AS is_failed
    FROM fact_payment p
    WHERE p.is_intercompany = 0
      AND p.sender_country <> p.receiver_country
      AND p.status <> 'pending'
)
SELECT corridor,
       sender_country,
       receiver_country,
       COUNT(*)                                        AS n_payments,
       ROUND(SUM(amount_sgd) / 1e6, 1)                 AS value_sgd_m,
       ROUND(AVG(hours_to_settle), 1)                  AS avg_hours,
       ROUND(100.0 * AVG(hours_to_settle > 48), 1)     AS pct_over_48h,
       ROUND(100.0 * SUM(is_failed) / COUNT(*), 1)     AS failure_pct
FROM xb
GROUP BY corridor, sender_country, receiver_country
HAVING n_payments >= 200;


-- -------------------------------------------------------------------------------------
-- vw_02_cube   ONE source for the whole Analysis 2 dashboard
-- -------------------------------------------------------------------------------------
-- One row per month x entity x corridor x rail, with sums and counts only, so a filter on any
-- field reaches every chart. Rebuild the scorecard in Tableau:
--   avg hours = SUM(sum_hours) / SUM(n_settled)    % over 48h = SUM(n_over_48h) / SUM(n_settled)
--   failure % = SUM(n_failed) / SUM(n_payments)
-- Same population as vw_02_corridor_scorecard (cross-border, no intercompany, not pending), but
-- without its ">= 200 payments" cut: filter on SUM(n_payments) in Tableau instead.
DROP VIEW IF EXISTS vw_02_cube;
CREATE VIEW vw_02_cube AS
SELECT date(p.initiated_ts, 'start of month')                  AS month_start,
       e.entity_id,
       e.name                                                  AS entity_name,
       p.sender_country || ' -> ' || p.receiver_country        AS corridor,
       p.sender_country,
       p.receiver_country,
       t.rail,
       COUNT(*)                                                AS n_payments,
       ROUND(SUM(p.amount_sgd), 2)                             AS value_sgd,
       SUM(p.settled_ts IS NOT NULL)                           AS n_settled,
       ROUND(SUM((julianday(p.settled_ts) - julianday(p.initiated_ts)) * 24), 2) AS sum_hours,
       SUM((julianday(p.settled_ts) - julianday(p.initiated_ts)) * 24 > 48)      AS n_over_48h,
       SUM(p.status IN ('rejected', 'returned'))               AS n_failed
FROM fact_payment p
JOIN dim_account      a ON a.account_id = p.account_id
JOIN dim_entity       e ON e.entity_id  = a.entity_id
JOIN dim_payment_type t ON t.type_id    = p.type_id
WHERE p.is_intercompany = 0
  AND p.sender_country <> p.receiver_country
  AND p.status <> 'pending'
GROUP BY month_start, e.entity_id, e.name, corridor, p.sender_country, p.receiver_country, t.rail;
