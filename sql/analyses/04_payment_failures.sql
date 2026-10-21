-- =====================================================================================
-- 04 · Payment failures
-- =====================================================================================
-- Question : why do payments fail, and can we stop it at the source?
-- Metrics  : failure rate; failure reasons ranked (Pareto); value at risk in failed payments;
--            repeat-offender counterparties.
-- Chart    : Pareto chart (bars = failures per reason, line = cumulative %).
-- So what  : most failures come from a few DATA causes (wrong account, missing address) that can
--            be fixed once in the vendor master data.
-- Tables   : fact_payment, dim_failure_reason, dim_counterparty
-- =====================================================================================


-- -------------------------------------------------------------------------------------
-- Step 1 ✅ given · Overall failure rate
-- -------------------------------------------------------------------------------------
SELECT COUNT(*)                                                       AS n_payments,
       SUM(status IN ('rejected', 'returned'))                        AS n_failed,
       ROUND(100.0 * AVG(status IN ('rejected', 'returned')), 2)      AS fail_rate_pct,
       ROUND(SUM(CASE WHEN status IN ('rejected', 'returned') THEN amount_sgd ELSE 0 END) / 1e6, 2)
                                                                      AS failed_value_sgd_m
FROM fact_payment
WHERE is_intercompany = 0
  AND direction = 'OUT'
  AND status <> 'pending';


-- -------------------------------------------------------------------------------------
-- Step 2 ✏️ TODO · Pareto of failure reasons
-- -------------------------------------------------------------------------------------
-- 1. Failed outgoing payments JOIN dim_failure_reason r ON r.reason_code = p.failure_reason.
-- 2. GROUP BY reason_code, description, category -> n_failed.
-- 3. Cumulative share with a running-total window:
--      100.0 * SUM(COUNT(*)) OVER (ORDER BY COUNT(*) DESC) / SUM(COUNT(*)) OVER ()  AS cum_pct
--    (window functions run AFTER GROUP BY, so you can window over the COUNT(*)s)
-- ✔️ expect: the top 3 reasons (AC01 and RR03 lead by far) cover ~70% of failures.
-- Then group by category instead: how much is "data" (fixable at source)?


-- -------------------------------------------------------------------------------------
-- Step 3 ✏️ TODO · Repeat offenders
-- -------------------------------------------------------------------------------------
-- Counterparties with the most failures:
--   GROUP BY counterparty_id, c.name, c.country
--   HAVING n_failed >= 5
--   ORDER BY n_failed DESC
-- Add their own fail rate (failed / all their payments). A supplier failing 30% of the time
-- has broken bank details in our master data.
-- ✔️ expect: a handful of suppliers stand out far above the rest.


-- -------------------------------------------------------------------------------------
-- Step 4 ✏️ TODO · Failure rate by rail and by month
-- -------------------------------------------------------------------------------------
-- Is it getting better or worse over time? Any month that spikes?


-- -------------------------------------------------------------------------------------
-- Step 5 ✅ · Views
-- -------------------------------------------------------------------------------------
-- vw_04_failure_pareto    failure reasons ranked, with share of failures and failed value
-- vw_04_repeat_offenders  counterparties with >= 5 failed payments
-- vw_04_risk_rating       failure rate by counterparty risk rating
-- vw_04_failure_rail      failure rate by rail
-- vw_04_failure_trend     failure rate by month

DROP VIEW IF EXISTS vw_04_failure_pareto;
CREATE VIEW vw_04_failure_pareto AS
SELECT p.failure_reason,
       dfr.description AS failure_description,
       dfr.category,
       COUNT(*)        AS n_payment_failures,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct_of_failures,
       ROUND(100.0 * SUM(COUNT(*)) OVER (ORDER BY COUNT(*) DESC) / SUM(COUNT(*)) OVER (), 1) AS cum_pct,
       ROUND(SUM(p.amount_sgd) / 1e6, 2) AS failed_value_sgd_m
FROM fact_payment p
JOIN dim_failure_reason dfr ON p.failure_reason = dfr.reason_code
WHERE p.is_intercompany = 0
  AND p.direction = 'OUT'
  AND p.status IN ('rejected', 'returned')
GROUP BY p.failure_reason, dfr.description, dfr.category;

DROP VIEW IF EXISTS vw_04_repeat_offenders;
CREATE VIEW vw_04_repeat_offenders AS
SELECT p.counterparty_id,
       cp.name,
       cp.counterparty_type,
       cp.country,
       cp.risk_rating,
       ROUND(cp.data_quality_score, 2) AS data_quality_score,
       COUNT(*) AS n_payments,
       SUM(p.status IN ('rejected', 'returned')) AS n_failed,
       ROUND(100.0 * AVG(p.status IN ('rejected', 'returned')), 1) AS fail_rate_pct,
       ROUND(SUM(CASE WHEN p.status IN ('rejected', 'returned') THEN p.amount_sgd ELSE 0 END) / 1e6, 2)
                                                                   AS failed_value_sgd_m
FROM fact_payment p
JOIN dim_counterparty cp ON p.counterparty_id = cp.counterparty_id
WHERE p.is_intercompany = 0
  AND p.direction = 'OUT'
  AND p.status <> 'pending'
GROUP BY p.counterparty_id, cp.name, cp.counterparty_type, cp.country, cp.risk_rating, cp.data_quality_score
HAVING n_failed >= 5;

DROP VIEW IF EXISTS vw_04_risk_rating;
CREATE VIEW vw_04_risk_rating AS
SELECT cp.risk_rating,
       COUNT(*) AS n_payments,
       SUM(p.status IN ('rejected', 'returned')) AS n_failed,
       ROUND(100.0 * AVG(p.status IN ('rejected', 'returned')), 1) AS fail_rate_pct,
       ROUND(SUM(CASE WHEN p.status IN ('rejected', 'returned') THEN p.amount_sgd ELSE 0 END) / 1e6, 2)
                                                                   AS failed_value_sgd_m
FROM fact_payment p
JOIN dim_counterparty cp ON p.counterparty_id = cp.counterparty_id
WHERE p.is_intercompany = 0
  AND p.direction = 'OUT'
  AND p.status <> 'pending'
GROUP BY cp.risk_rating;

DROP VIEW IF EXISTS vw_04_failure_rail;
CREATE VIEW vw_04_failure_rail AS
SELECT t.rail,
       COUNT(*)                                                    AS n_payments,
       SUM(p.status IN ('rejected', 'returned'))                   AS n_failed,
       ROUND(100.0 * AVG(p.status IN ('rejected', 'returned')), 2) AS fail_rate_pct,
       ROUND(SUM(CASE WHEN p.status IN ('rejected', 'returned') THEN p.amount_sgd ELSE 0 END) / 1e6, 2)
                                                                   AS failed_value_sgd_m
FROM fact_payment p
JOIN dim_payment_type t ON t.type_id = p.type_id
WHERE p.is_intercompany = 0
  AND p.direction = 'OUT'
  AND p.status <> 'pending'
GROUP BY t.rail;

DROP VIEW IF EXISTS vw_04_failure_trend;
CREATE VIEW vw_04_failure_trend AS
SELECT strftime('%Y-%m', p.initiated_ts)                           AS month,
       date(p.initiated_ts, 'start of month')                      AS month_start,   -- a real date for the time axis
       COUNT(*)                                                    AS n_payments,
       SUM(p.status IN ('rejected', 'returned'))                   AS n_failed,
       ROUND(100.0 * AVG(p.status IN ('rejected', 'returned')), 2) AS fail_rate_pct,
       ROUND(SUM(CASE WHEN p.status IN ('rejected', 'returned') THEN p.amount_sgd ELSE 0 END) / 1e6, 2)
                                                                   AS failed_value_sgd_m
FROM fact_payment p
WHERE p.is_intercompany = 0
  AND p.direction = 'OUT'
  AND p.status <> 'pending'
GROUP BY month;


-- -------------------------------------------------------------------------------------
-- vw_04_cube   ONE source for the whole Analysis 4 dashboard
-- -------------------------------------------------------------------------------------
-- One row per month x entity x rail x counterparty x failure reason (failure_reason is empty for
-- payments that did not fail), with counts and sums only. Rebuild in Tableau:
--   fail rate % = SUM(n_failed) / SUM(n_payments)         pareto: filter n_failed > 0, rank by reason
--   repeat offenders: group by counterparty, keep SUM(n_failed) >= 5
-- Same population as the vw_04_* views (our outbound payments, no intercompany, not pending).
DROP VIEW IF EXISTS vw_04_cube;
CREATE VIEW vw_04_cube AS
SELECT date(p.initiated_ts, 'start of month')                  AS month_start,
       e.entity_id,
       e.name                                                  AS entity_name,
       t.rail,
       p.counterparty_id,
       cp.name                                                 AS counterparty_name,
       cp.counterparty_type,
       cp.country                                              AS counterparty_country,
       cp.risk_rating,
       ROUND(cp.data_quality_score, 2)                         AS data_quality_score,
       p.failure_reason,
       dfr.description                                         AS failure_description,
       dfr.category                                            AS failure_category,
       COUNT(*)                                                AS n_payments,
       SUM(p.status IN ('rejected', 'returned'))               AS n_failed,
       ROUND(SUM(CASE WHEN p.status IN ('rejected', 'returned') THEN p.amount_sgd ELSE 0 END), 2)
                                                               AS failed_value_sgd
FROM fact_payment p
JOIN dim_account      a  ON a.account_id      = p.account_id
JOIN dim_entity       e  ON e.entity_id       = a.entity_id
JOIN dim_payment_type t  ON t.type_id         = p.type_id
JOIN dim_counterparty cp ON cp.counterparty_id = p.counterparty_id
LEFT JOIN dim_failure_reason dfr ON dfr.reason_code = p.failure_reason
WHERE p.is_intercompany = 0
  AND p.direction = 'OUT'
  AND p.status <> 'pending'
GROUP BY month_start, e.entity_id, e.name, t.rail, p.counterparty_id, cp.name, cp.counterparty_type,
         cp.country, cp.risk_rating, cp.data_quality_score, p.failure_reason, dfr.description, dfr.category;
