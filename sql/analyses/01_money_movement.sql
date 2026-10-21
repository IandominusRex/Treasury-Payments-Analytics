-- =====================================================================================
-- 01 · Where is money moving?
-- =====================================================================================
-- Question : which entities, countries and currencies carry the most volume, and at what scale?
-- Metrics  : total value by currency, by corridor (sender country -> receiver country),
--            by entity; payment counts.
-- Chart    : corridor heat map (sender x receiver) or Sankey; bar of top currencies.
-- So what  : reveals FX exposure, dependence on certain corridors, candidates for netting.
-- Tables   : fact_payment, dim_account, dim_entity
-- =====================================================================================


-- -------------------------------------------------------------------------------------
-- Step 1 · The base set: settled, external payments, labelled with our entity.
-- -------------------------------------------------------------------------------------
-- Read each line and say out loud why it's there:
--   * is_intercompany = 0  -> internal transfers are not "money moving" for the group
--   * status completed/delayed -> only money that actually moved
--   * dim_account -> dim_entity  -> payments point to an ACCOUNT; the account knows the company
WITH base AS (
    SELECT p.payment_id,
           e.entity_id,
           e.name            AS entity_name,
           p.direction,
           p.sender_country,
           p.receiver_country,
           p.currency_code,
           p.amount_sgd,
           date(p.initiated_ts) AS pay_date
    FROM fact_payment p
    JOIN dim_account a ON a.account_id = p.account_id
    JOIN dim_entity  e ON e.entity_id  = a.entity_id
    WHERE p.is_intercompany = 0
      AND p.status IN ('completed', 'delayed')
)
SELECT * FROM base LIMIT 20;


-- -------------------------------------------------------------------------------------
-- Step 2 · Save as views for the dashboard (one view per chart)
-- -------------------------------------------------------------------------------------
-- Views store the QUERY, not the result: they re-run each time, so they stay current when
-- new data arrives (including live stream mode).
-- vw_01_currency   value and count per currency
-- vw_01_corridor   cross-border corridors by value (all corridors; the dashboard takes the top N);
--                  sender / receiver country are separate columns so a map can use them
-- vw_01_entity     inflow / outflow / net per entity
-- vw_01_monthly    monthly value, inflow, outflow and net (SGD m)

DROP VIEW IF EXISTS vw_01_currency;
CREATE VIEW vw_01_currency AS
SELECT p.currency_code,
       COUNT(*)                          AS n_payments,
       ROUND(SUM(p.amount_sgd) / 1e6, 1) AS value_sgd_m
FROM fact_payment p
WHERE p.is_intercompany = 0
  AND p.status IN ('completed', 'delayed')
GROUP BY p.currency_code;

DROP VIEW IF EXISTS vw_01_corridor;
CREATE VIEW vw_01_corridor AS
SELECT p.sender_country || ' -> ' || p.receiver_country AS corridor,
       p.sender_country,
       p.receiver_country,
       COUNT(*)                          AS n_payments,
       ROUND(SUM(p.amount_sgd) / 1e6, 1) AS value_sgd_m
FROM fact_payment p
WHERE p.is_intercompany = 0
  AND p.status IN ('completed', 'delayed')
  AND p.sender_country <> p.receiver_country
GROUP BY p.sender_country, p.receiver_country;

DROP VIEW IF EXISTS vw_01_entity;
CREATE VIEW vw_01_entity AS
SELECT e.entity_id,
       e.name AS entity_name,
       ROUND(SUM(CASE WHEN p.direction = 'IN'  THEN p.amount_sgd ELSE 0 END), 2) AS inflow_sgd,
       ROUND(SUM(CASE WHEN p.direction = 'OUT' THEN p.amount_sgd ELSE 0 END), 2) AS outflow_sgd,
       ROUND(SUM(CASE WHEN p.direction = 'IN' THEN p.amount_sgd ELSE -p.amount_sgd END), 2) AS net_inflow_sgd
FROM fact_payment p
JOIN dim_account a ON a.account_id = p.account_id
JOIN dim_entity  e ON e.entity_id  = a.entity_id
WHERE p.is_intercompany = 0
  AND p.status IN ('completed', 'delayed')
GROUP BY e.entity_id, e.name;

DROP VIEW IF EXISTS vw_01_monthly;
CREATE VIEW vw_01_monthly AS
SELECT strftime('%Y-%m', p.initiated_ts)    AS month,
       date(p.initiated_ts, 'start of month') AS month_start,      -- a real date: Tableau needs one for a time axis
       COUNT(*)                          AS n_payments,
       ROUND(SUM(p.amount_sgd) / 1e6, 1) AS value_sgd_m,
       ROUND(SUM(CASE WHEN p.direction = 'IN'  THEN p.amount_sgd ELSE 0 END) / 1e6, 1) AS inflow_sgd_m,
       ROUND(SUM(CASE WHEN p.direction = 'OUT' THEN p.amount_sgd ELSE 0 END) / 1e6, 1) AS outflow_sgd_m,
       ROUND(SUM(CASE WHEN p.direction = 'IN' THEN p.amount_sgd ELSE -p.amount_sgd END) / 1e6, 1) AS net_inflow_sgd_m
FROM fact_payment p
WHERE p.is_intercompany = 0
  AND p.status IN ('completed', 'delayed')
GROUP BY month;


-- -------------------------------------------------------------------------------------
-- vw_01_cube   ONE source for the whole Analysis 1 dashboard
-- -------------------------------------------------------------------------------------
-- The four views above each feed one chart, so in Tableau they are four separate data sources
-- and a click or filter on one chart cannot reach the others. This view has every filter
-- field in one table (month, entity, currency, sender / receiver country), so all four charts
-- can use it and one filter drives them all. Only sums and counts are stored (they add up under
-- any filter); build the charts from them:
--   net inflow = SUM(inflow_sgd) - SUM(outflow_sgd)      corridor chart: filter is_cross_border = 1
-- Same population as the views above (no intercompany, completed / delayed only).
DROP VIEW IF EXISTS vw_01_cube;
CREATE VIEW vw_01_cube AS
SELECT date(p.initiated_ts, 'start of month')                  AS month_start,
       e.entity_id,
       e.name                                                  AS entity_name,
       p.currency_code,
       p.sender_country,
       p.receiver_country,
       p.sender_country || ' -> ' || p.receiver_country        AS corridor,
       CASE WHEN p.sender_country <> p.receiver_country THEN 1 ELSE 0 END AS is_cross_border,
       COUNT(*)                                                AS n_payments,
       ROUND(SUM(p.amount_sgd), 2)                             AS value_sgd,
       ROUND(SUM(CASE WHEN p.direction = 'IN'  THEN p.amount_sgd ELSE 0 END), 2) AS inflow_sgd,
       ROUND(SUM(CASE WHEN p.direction = 'OUT' THEN p.amount_sgd ELSE 0 END), 2) AS outflow_sgd
FROM fact_payment p
JOIN dim_account a ON a.account_id = p.account_id
JOIN dim_entity  e ON e.entity_id  = a.entity_id
WHERE p.is_intercompany = 0
  AND p.status IN ('completed', 'delayed')
GROUP BY month_start, e.entity_id, e.name, p.currency_code, p.sender_country, p.receiver_country;
