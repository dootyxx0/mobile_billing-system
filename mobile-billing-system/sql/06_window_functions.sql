-- ============================================================
-- ОКОННЫЕ ФУНКЦИИ
-- ============================================================

-- ПРИМЕР 1: топ-абонентов по тратам за месяц (через CDR)
-- RANK() — абоненты с одинаковой суммой получают одинаковый ранг.
SELECT
    s.last_name || ' ' || s.first_name AS subscriber_name,
    c.phone_number,
    TO_CHAR(cdr.started_at, 'YYYY-MM') AS billing_month,
    SUM(cdr.cost) AS month_spending,
    RANK() OVER (
        PARTITION BY TO_CHAR(cdr.started_at, 'YYYY-MM')
        ORDER BY SUM(cdr.cost) DESC
    ) AS spending_rank
FROM cdr
JOIN contracts c ON cdr.contract_id = c.contract_id
JOIN subscribers s ON c.subscriber_id = s.subscriber_id
GROUP BY s.last_name, s.first_name, c.phone_number, TO_CHAR(cdr.started_at, 'YYYY-MM')
ORDER BY billing_month, spending_rank;


-- ПРИМЕР 2: накопительная выручка по дням (платежи)
-- SUM() OVER с рамкой ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW —
-- показывает нарастающий итог поступлений по дням, как в финансовой отчётности.
SELECT
    p.paid_at::DATE AS payment_day,
    p.amount,
    SUM(p.amount) OVER (
        ORDER BY p.paid_at
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS cumulative_revenue
FROM payments p
ORDER BY p.paid_at;


-- ПРИМЕР 3: ранжирование тарифных планов по количеству подключённых
-- договоров (популярность тарифа) с использованием DENSE_RANK
SELECT
    tp.name AS tariff_name,
    COUNT(c.contract_id) AS active_contracts,
    DENSE_RANK() OVER (ORDER BY COUNT(c.contract_id) DESC) AS popularity_rank
FROM tariff_plans tp
LEFT JOIN contracts c ON c.tariff_id = tp.tariff_id AND c.status = 'active'
GROUP BY tp.tariff_id, tp.name
ORDER BY popularity_rank;


-- ПРИМЕР 4: динамика расходов абонента месяц к месяцу (LAG)
-- Позволяет увидеть, выросли или упали траты по сравнению с прошлым месяцем.
SELECT
    c.phone_number,
    TO_CHAR(cdr.started_at, 'YYYY-MM') AS billing_month,
    SUM(cdr.cost) AS month_spending,
    LAG(SUM(cdr.cost)) OVER (
        PARTITION BY c.phone_number
        ORDER BY TO_CHAR(cdr.started_at, 'YYYY-MM')
    ) AS prev_month_spending
FROM cdr
JOIN contracts c ON cdr.contract_id = c.contract_id
GROUP BY c.phone_number, TO_CHAR(cdr.started_at, 'YYYY-MM')
ORDER BY c.phone_number, billing_month;


-- ============================================================
-- РЕКУРСИВНЫЙ ЗАПРОС (CTE)
-- ============================================================

-- Иерархия тарифных планов: некоторые тарифы являются "надстройкой"
-- над базовым (например, "Безлимитище 2.0" наследуется от "Безлимитище").
-- Рекурсивный CTE строит полную цепочку наследования и уровень вложенности —
-- полезно, когда нужно понять, на основе какого "базового" тарифа
-- сформирован любой производный тарифный план.
WITH RECURSIVE tariff_hierarchy AS (
    -- Базовый случай: тарифы без родителя (корневые)
    SELECT
        tariff_id,
        parent_tariff_id,
        name,
        monthly_fee,
        0 AS level,
        name::TEXT AS hierarchy_path
    FROM tariff_plans
    WHERE parent_tariff_id IS NULL

    UNION ALL

    -- Рекурсивный шаг: находим тарифы, у которых parent_tariff_id
    -- ссылается на уже обработанный тариф
    SELECT
        tp.tariff_id,
        tp.parent_tariff_id,
        tp.name,
        tp.monthly_fee,
        th.level + 1,
        th.hierarchy_path || ' -> ' || tp.name
    FROM tariff_plans tp
    JOIN tariff_hierarchy th ON tp.parent_tariff_id = th.tariff_id
)
SELECT
    tariff_id,
    name,
    monthly_fee,
    level,
    hierarchy_path
FROM tariff_hierarchy
ORDER BY hierarchy_path;
