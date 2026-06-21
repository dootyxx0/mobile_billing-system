-- ============================================================
-- ФУНКЦИИ (PL/pgSQL)
-- ============================================================

-- ФУНКЦИЯ 1: расчёт стоимости звонка с учётом тарифа, лимита пакета
-- минут и множителя роуминговой зоны.
-- Если у абонента ещё остались минуты в пакете за текущий месяц —
-- звонок бесплатный, иначе считается по цене тарифа с учётом зоны.
CREATE OR REPLACE FUNCTION calculate_call_cost(
    p_contract_id INT,
    p_duration_seconds INT,
    p_zone_id INT,
    p_call_date TIMESTAMP
)
RETURNS NUMERIC AS $$
DECLARE
    v_tariff_id INT;
    v_included_minutes INT;
    v_price_per_minute NUMERIC;
    v_used_minutes NUMERIC;
    v_multiplier NUMERIC;
    v_call_minutes NUMERIC;
    v_cost NUMERIC;
BEGIN
    -- Получаем тариф абонента
    SELECT tp.tariff_id, tp.included_minutes, tp.price_per_minute
    INTO v_tariff_id, v_included_minutes, v_price_per_minute
    FROM contracts c
    JOIN tariff_plans tp ON c.tariff_id = tp.tariff_id
    WHERE c.contract_id = p_contract_id;

    IF v_tariff_id IS NULL THEN
        RAISE EXCEPTION 'Договор % не найден', p_contract_id;
    END IF;

    -- Сколько минут уже использовано за месяц (без учёта текущего звонка)
    SELECT COALESCE(SUM(duration_seconds), 0) / 60.0
    INTO v_used_minutes
    FROM cdr
    WHERE contract_id = p_contract_id
      AND record_type = 'call'
      AND DATE_TRUNC('month', started_at) = DATE_TRUNC('month', p_call_date);

    v_call_minutes := p_duration_seconds / 60.0;

    -- Множитель зоны (роуминг увеличивает стоимость минуты)
    SELECT COALESCE(minute_multiplier, 1.0) INTO v_multiplier
    FROM roaming_zones WHERE zone_id = p_zone_id;

    IF v_multiplier IS NULL THEN
        v_multiplier := 1.0;
    END IF;

    -- Если в пределах пакета минут — бесплатно (только для домашней зоны)
    IF v_used_minutes + v_call_minutes <= v_included_minutes AND v_multiplier = 1.0 THEN
        v_cost := 0;
    ELSE
        v_cost := ROUND(v_call_minutes * v_price_per_minute * v_multiplier, 2);
    END IF;

    RETURN v_cost;
END;
$$ LANGUAGE plpgsql;


-- ФУНКЦИЯ 2: формирование счёта за период — собирает абонентскую плату,
-- стоимость подключённых услуг и сумму всех CDR-записей за период,
-- создаёт invoice и сразу детализацию invoice_items.
CREATE OR REPLACE FUNCTION generate_invoice(
    p_contract_id INT,
    p_period_start DATE,
    p_period_end DATE
)
RETURNS INT AS $$
DECLARE
    v_invoice_id INT;
    v_tariff_fee NUMERIC;
    v_tariff_name VARCHAR;
    v_services_total NUMERIC;
    v_calls_total NUMERIC;
    v_data_total NUMERIC;
    v_total NUMERIC;
BEGIN
    SELECT tp.monthly_fee, tp.name INTO v_tariff_fee, v_tariff_name
    FROM contracts c
    JOIN tariff_plans tp ON c.tariff_id = tp.tariff_id
    WHERE c.contract_id = p_contract_id;

    SELECT COALESCE(SUM(s.monthly_price), 0) INTO v_services_total
    FROM contract_services cs
    JOIN services s ON cs.service_id = s.service_id
    WHERE cs.contract_id = p_contract_id
      AND cs.activated_at <= p_period_end
      AND (cs.deactivated_at IS NULL OR cs.deactivated_at >= p_period_start);

    SELECT COALESCE(SUM(cost), 0) INTO v_calls_total
    FROM cdr
    WHERE contract_id = p_contract_id
      AND record_type IN ('call', 'sms')
      AND started_at BETWEEN p_period_start AND p_period_end;

    SELECT COALESCE(SUM(cost), 0) INTO v_data_total
    FROM cdr
    WHERE contract_id = p_contract_id
      AND record_type = 'data'
      AND started_at BETWEEN p_period_start AND p_period_end;

    v_total := v_tariff_fee + v_services_total + v_calls_total + v_data_total;

    INSERT INTO invoices (contract_id, period_start, period_end, total_amount, status, due_date)
    VALUES (p_contract_id, p_period_start, p_period_end, v_total, 'issued', p_period_end + INTERVAL '15 days')
    RETURNING invoice_id INTO v_invoice_id;

    INSERT INTO invoice_items (invoice_id, item_type, description, amount)
    VALUES (v_invoice_id, 'subscription_fee', 'Абонентская плата «' || v_tariff_name || '»', v_tariff_fee);

    IF v_services_total > 0 THEN
        INSERT INTO invoice_items (invoice_id, item_type, description, amount)
        VALUES (v_invoice_id, 'service_fee', 'Дополнительные услуги', v_services_total);
    END IF;

    IF v_calls_total > 0 THEN
        INSERT INTO invoice_items (invoice_id, item_type, description, amount)
        VALUES (v_invoice_id, 'overage_minutes', 'Звонки/SMS сверх пакета', v_calls_total);
    END IF;

    IF v_data_total > 0 THEN
        INSERT INTO invoice_items (invoice_id, item_type, description, amount)
        VALUES (v_invoice_id, 'overage_data', 'Интернет сверх пакета', v_data_total);
    END IF;

    RETURN v_invoice_id;
END;
$$ LANGUAGE plpgsql;


-- ФУНКЦИЯ 3: процент абонентов с задолженностью по тарифу
-- (доля договоров с отрицательным балансом среди всех на данном тарифе)
CREATE OR REPLACE FUNCTION get_debt_ratio_by_tariff(p_tariff_id INT)
RETURNS NUMERIC AS $$
DECLARE
    v_total INT;
    v_in_debt INT;
BEGIN
    SELECT COUNT(*) INTO v_total
    FROM contracts
    WHERE tariff_id = p_tariff_id;

    IF v_total = 0 THEN
        RETURN 0;
    END IF;

    SELECT COUNT(*) INTO v_in_debt
    FROM contracts
    WHERE tariff_id = p_tariff_id AND balance < 0;

    RETURN ROUND((v_in_debt::NUMERIC / v_total) * 100, 2);
END;
$$ LANGUAGE plpgsql;


-- ФУНКЦИЯ 4: суммарный расход абонента за произвольный период
-- (по CDR + оплаченным счетам) — пригодится для клиентской поддержки
CREATE OR REPLACE FUNCTION get_subscriber_spending(
    p_contract_id INT,
    p_from DATE,
    p_to DATE
)
RETURNS NUMERIC AS $$
DECLARE
    v_spending NUMERIC;
BEGIN
    SELECT COALESCE(SUM(total_amount), 0)
    INTO v_spending
    FROM invoices
    WHERE contract_id = p_contract_id
      AND period_start >= p_from
      AND period_end <= p_to;

    RETURN v_spending;
END;
$$ LANGUAGE plpgsql;
