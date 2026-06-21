-- ============================================================
-- ПРЕДСТАВЛЕНИЯ (VIEW)
-- ============================================================

-- VIEW 1: текущее состояние договоров (баланс, тариф, статус)
-- Удобно для дашборда оператора — видно всё ключевое по абоненту в одном месте
CREATE OR REPLACE VIEW v_contract_overview AS
SELECT
    c.contract_id,
    s.last_name || ' ' || s.first_name AS subscriber_name,
    c.phone_number,
    tp.name AS tariff_name,
    c.balance,
    c.credit_limit,
    c.status,
    CASE
        WHEN c.balance < 0 THEN 'Долг'
        WHEN c.balance < tp.monthly_fee THEN 'Низкий баланс'
        ELSE 'В норме'
    END AS balance_state
FROM contracts c
JOIN subscribers s ON c.subscriber_id = s.subscriber_id
JOIN tariff_plans tp ON c.tariff_id = tp.tariff_id;

-- VIEW 2: детализация звонков/SMS/интернета с указанием абонента и зоны
CREATE OR REPLACE VIEW v_cdr_detailed AS
SELECT
    cdr.cdr_id,
    c.phone_number,
    s.last_name || ' ' || s.first_name AS subscriber_name,
    cdr.record_type,
    rz.zone_name,
    cdr.started_at,
    cdr.duration_seconds,
    cdr.data_volume_mb,
    cdr.cost
FROM cdr
JOIN contracts c ON cdr.contract_id = c.contract_id
JOIN subscribers s ON c.subscriber_id = s.subscriber_id
LEFT JOIN roaming_zones rz ON cdr.zone_id = rz.zone_id;

-- VIEW 3: счета с фактическим статусом оплаты и суммой платежей
CREATE OR REPLACE VIEW v_invoice_payment_status AS
SELECT
    i.invoice_id,
    c.phone_number,
    i.period_start,
    i.period_end,
    i.total_amount,
    COALESCE(SUM(p.amount), 0) AS paid_amount,
    i.total_amount - COALESCE(SUM(p.amount), 0) AS remaining_amount,
    i.status,
    i.due_date
FROM invoices i
JOIN contracts c ON i.contract_id = c.contract_id
LEFT JOIN payments p ON p.invoice_id = i.invoice_id
GROUP BY i.invoice_id, c.phone_number, i.period_start, i.period_end,
         i.total_amount, i.status, i.due_date;

-- ============================================================
-- МАТЕРИАЛИЗОВАННОЕ ПРЕДСТАВЛЕНИЕ
-- ============================================================

-- Выручка по тарифам и месяцам — тяжёлый агрегирующий запрос,
-- для реальной BSS-системы такие отчёты обычно не считают "на лету",
-- а обновляют по расписанию (REFRESH MATERIALIZED VIEW)
CREATE MATERIALIZED VIEW mv_revenue_by_tariff_month AS
SELECT
    TO_CHAR(i.period_start, 'YYYY-MM') AS billing_month,
    tp.name AS tariff_name,
    COUNT(DISTINCT i.contract_id) AS subscriber_count,
    SUM(i.total_amount) AS total_revenue,
    ROUND(AVG(i.total_amount), 2) AS avg_revenue_per_subscriber
FROM invoices i
JOIN contracts c ON i.contract_id = c.contract_id
JOIN tariff_plans tp ON c.tariff_id = tp.tariff_id
GROUP BY TO_CHAR(i.period_start, 'YYYY-MM'), tp.name
ORDER BY billing_month, tariff_name;

-- Индекс на материализованном представлении (нужен для REFRESH CONCURRENTLY)
CREATE UNIQUE INDEX idx_mv_revenue_month_tariff
    ON mv_revenue_by_tariff_month (billing_month, tariff_name);

-- Команда обновления (выполняется по расписанию, например через cron/pg_cron):
-- REFRESH MATERIALIZED VIEW CONCURRENTLY mv_revenue_by_tariff_month;
