-- =====================================================================================
-- 05 · Liquidity position
-- =====================================================================================
-- Question : how much cash does each entity and currency hold, and how does it move?
-- Method   : daily closing balance and settled net cash flow per entity and currency, a weekly
--            series, and the average flow by day of week (the payment-run rhythm).
-- Metrics  : closing balance, net and gross flow, average net flow by weekday.
-- Chart    : closing balance over time; average net inflow by weekday.
-- So what  : lets treasury see a shortfall early and fund it cheaply instead of via overdraft.
-- Tables   : fact_balance, fact_payment, fact_fx_rate, dim_account, dim_entity, dim_date
--
-- SQL's job here: build clean daily/weekly time series. A 13-week forecast would read the same
-- series (notebooks/05_forecast.ipynb); it is not built.
-- =====================================================================================


-- -------------------------------------------------------------------------------------
-- Step 1 · Daily closing balance per entity and currency
-- -------------------------------------------------------------------------------------
-- fact_balance is one row per account per day. Sum accounts up to entity + currency.
-- Keep the ORIGINAL currency here: converting to SGD would mix FX moves into the balance.
SELECT b.date_id,
       a.entity_id,
       a.currency_code,
       ROUND(SUM(b.closing_balance), 2) AS closing_balance
FROM fact_balance b
JOIN dim_account a ON a.account_id = b.account_id
GROUP BY b.date_id, a.entity_id, a.currency_code
ORDER BY a.entity_id, a.currency_code, b.date_id
LIMIT 30;


-- -------------------------------------------------------------------------------------
-- Step 2 · Views for the dashboard
-- -------------------------------------------------------------------------------------
-- vw_05_daily_balance     closing balance per day, entity and currency (own currency and SGD)
-- vw_05_daily_net_flow    settled net and gross flow per day, entity and currency (own currency and SGD)
-- vw_05_weekly_net_flow   the same by week (week_start = the Monday)
-- vw_05_weekday_pattern   average net / gross flow by day of week (the payment-run rhythm)
-- Amounts in the *_sgd columns can be summed across currencies and entities; the own-currency
-- columns cannot (only add them up within one currency).
-- Net flow uses the settlement DATE (settled_ts), not initiation: cash moves when it settles.
-- Intercompany payments are kept: from one entity's point of view, funding from HQ is real cash
-- (analysis 01 leaves them out because it looks at money moving in and out of the group).
-- In Python:  pd.read_sql("SELECT * FROM vw_05_daily_net_flow", con)

DROP VIEW IF EXISTS vw_05_daily_balance;
CREATE VIEW vw_05_daily_balance AS
SELECT b.date_id, a.entity_id, e.name AS entity_name, a.currency_code,
       ROUND(SUM(b.closing_balance), 2)                    AS closing_balance,
       ROUND(SUM(b.closing_balance * fx.rate_to_sgd), 2)   AS closing_balance_sgd
FROM fact_balance b
JOIN dim_account a   ON a.account_id = b.account_id
JOIN dim_entity e    ON e.entity_id = a.entity_id
JOIN fact_fx_rate fx ON fx.date_id = b.date_id AND fx.currency_code = b.currency_code
GROUP BY b.date_id, a.entity_id, e.name, a.currency_code;

DROP VIEW IF EXISTS vw_05_daily_net_flow;
CREATE VIEW vw_05_daily_net_flow AS
SELECT CAST(strftime('%Y%m%d', p.settled_ts) AS INTEGER) AS date_id,
       a.entity_id, e.name AS entity_name, a.currency_code,
       ROUND(SUM(CASE WHEN p.direction = 'IN' THEN p.amount ELSE -p.amount END), 2)         AS net_flow,
       ROUND(SUM(p.amount), 2)                                                              AS gross_flow,
       ROUND(SUM(CASE WHEN p.direction = 'IN' THEN p.amount_sgd ELSE -p.amount_sgd END), 2) AS net_flow_sgd,
       ROUND(SUM(p.amount_sgd), 2)                                                          AS gross_flow_sgd
FROM fact_payment p
JOIN dim_account a ON a.account_id = p.account_id
JOIN dim_entity e  ON e.entity_id = a.entity_id
WHERE p.status IN ('completed', 'delayed') AND p.settled_ts IS NOT NULL   -- delayed payments settle too
GROUP BY 1, 2, 3, 4;

DROP VIEW IF EXISTS vw_05_weekly_net_flow;
CREATE VIEW vw_05_weekly_net_flow AS
SELECT date(d.date, '-' || d.day_of_week || ' days') AS week_start,      -- day_of_week: 0 = Monday
       f.entity_id, f.entity_name, f.currency_code,
       ROUND(SUM(f.net_flow), 2)     AS weekly_net_flow,
       ROUND(SUM(f.net_flow_sgd), 2) AS weekly_net_flow_sgd,
       COUNT(*)                      AS active_days
FROM vw_05_daily_net_flow f
JOIN dim_date d ON d.date_id = f.date_id
GROUP BY week_start, f.entity_id, f.entity_name, f.currency_code;

DROP VIEW IF EXISTS vw_05_weekday_pattern;
CREATE VIEW vw_05_weekday_pattern AS
SELECT d.day_of_week,
       CASE d.day_of_week WHEN 0 THEN 'Mon' WHEN 1 THEN 'Tue' WHEN 2 THEN 'Wed' WHEN 3 THEN 'Thu'
                          WHEN 4 THEN 'Fri' WHEN 5 THEN 'Sat' ELSE 'Sun' END AS weekday,
       f.entity_id, f.entity_name, f.currency_code,
       COUNT(*)                        AS n_days,
       ROUND(AVG(f.net_flow), 2)       AS avg_net_flow,
       ROUND(AVG(f.gross_flow), 2)     AS avg_gross_flow,
       ROUND(AVG(f.net_flow_sgd), 2)   AS avg_net_flow_sgd,
       ROUND(AVG(f.gross_flow_sgd), 2) AS avg_gross_flow_sgd
FROM vw_05_daily_net_flow f
JOIN dim_date d ON d.date_id = f.date_id
GROUP BY d.day_of_week, f.entity_id, f.entity_name, f.currency_code;


-- -------------------------------------------------------------------------------------
-- vw_05_cube   ONE source for the whole Analysis 5 dashboard
-- -------------------------------------------------------------------------------------
-- One row per day x entity x currency, so a filter on any field reaches every chart. It replaces
-- the four views above, which are built from it again in Tableau:
--   balance over time   SUM(closing_balance_sgd)   a snapshot: add up entities / currencies on ONE day,
--                       never across days (use the last day of the week / month, or AVG per day)
--   net flow            SUM(net_flow_sgd)          weekly chart: group by week_start
--   weekday rhythm      SUM(net_flow_sgd) / COUNTD(IF [flow_day] = 1 THEN [date] END), grouped by weekday
-- The own-currency columns (closing_balance, net_flow, gross_flow) only add up within ONE currency.
-- flow_day = 1 when anything settled that day. Days without a settlement have NULL flows, so the
-- weekday average counts only days with payments (the same as vw_05_weekday_pattern).
-- FULL OUTER JOIN: payments settle on 2026-10-01, one day past the last balance, and are kept.
DROP VIEW IF EXISTS vw_05_cube;
CREATE VIEW vw_05_cube AS
SELECT d.date_id,
       date(d.date, '-' || d.day_of_week || ' days')          AS week_start,   -- the Monday
       d.day_of_week,
       CASE d.day_of_week WHEN 0 THEN 'Mon' WHEN 1 THEN 'Tue' WHEN 2 THEN 'Wed' WHEN 3 THEN 'Thu'
                          WHEN 4 THEN 'Fri' WHEN 5 THEN 'Sat' ELSE 'Sun' END AS weekday,
       COALESCE(b.entity_id, f.entity_id)                     AS entity_id,
       COALESCE(b.entity_name, f.entity_name)                 AS entity_name,
       COALESCE(b.currency_code, f.currency_code)             AS currency_code,
       b.closing_balance,
       b.closing_balance_sgd,
       f.net_flow,
       f.gross_flow,
       f.net_flow_sgd,
       f.gross_flow_sgd,
       CASE WHEN f.date_id IS NOT NULL THEN 1 ELSE 0 END      AS flow_day
FROM vw_05_daily_balance b
FULL OUTER JOIN vw_05_daily_net_flow f
       ON f.date_id = b.date_id AND f.entity_id = b.entity_id AND f.currency_code = b.currency_code
JOIN dim_date d ON d.date_id = COALESCE(b.date_id, f.date_id);
