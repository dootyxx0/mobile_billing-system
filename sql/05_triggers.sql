-- ============================================================
-- ТРИГГЕРЫ
-- ============================================================

-- ТРИГГЕР 1: автоматическое обновление баланса договора
-- при добавлении записи в balance_transactions.
-- Срабатывает AFTER INSERT — баланс в contracts всегда синхронен
-- с историей транзакций, без ручного UPDATE из приложения.
CREATE OR REPLACE FUNCTION fn_update_balance_on_transaction()
RETURNS TRIGGER AS $$
BEGIN
    UPDATE contracts
    SET balance = balance + NEW.amount
    WHERE contract_id = NEW.contract_id;

    -- Фиксируем итоговый баланс прямо в строке транзакции (для истории)
    UPDATE balance_transactions
    SET balance_after = (SELECT balance FROM contracts WHERE contract_id = NEW.contract_id)
    WHERE transaction_id = NEW.transaction_id;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_update_balance_on_transaction
AFTER INSERT ON balance_transactions
FOR EACH ROW EXECUTE FUNCTION fn_update_balance_on_transaction();


-- ТРИГГЕР 2: автоблокировка номера при превышении кредитного лимита.
-- Срабатывает AFTER UPDATE баланса в contracts. Если баланс ушёл
-- в минус глубже, чем разрешённый credit_limit, статус меняется
-- на 'suspended' — типичная бизнес-логика биллинга оператора связи.
CREATE OR REPLACE FUNCTION fn_check_credit_limit()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.balance < -NEW.credit_limit AND NEW.status = 'active' THEN
        NEW.status := 'suspended';
        RAISE NOTICE 'Договор % приостановлен: превышен кредитный лимит', NEW.contract_id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_credit_limit
BEFORE UPDATE ON contracts
FOR EACH ROW
WHEN (NEW.balance IS DISTINCT FROM OLD.balance)
EXECUTE FUNCTION fn_check_credit_limit();


-- ТРИГГЕР 3: запрет начисления CDR для приостановленных/расторгнутых
-- договоров. Срабатывает BEFORE INSERT на cdr — нельзя тарифицировать
-- звонки абонента, который заблокирован.
CREATE OR REPLACE FUNCTION fn_block_cdr_for_inactive_contract()
RETURNS TRIGGER AS $$
DECLARE
    v_status VARCHAR;
BEGIN
    SELECT status INTO v_status FROM contracts WHERE contract_id = NEW.contract_id;

    IF v_status = 'terminated' THEN
        RAISE EXCEPTION 'Невозможно добавить запись CDR: договор % расторгнут', NEW.contract_id;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_block_cdr_for_inactive_contract
BEFORE INSERT ON cdr
FOR EACH ROW EXECUTE FUNCTION fn_block_cdr_for_inactive_contract();


-- ТРИГГЕР 4: контроль уникальности активной подключённой услуги.
-- Срабатывает BEFORE INSERT на contract_services — нельзя повторно
-- подключить услугу, которая уже активна (не имеет deactivated_at) на
-- этом договоре.
CREATE OR REPLACE FUNCTION fn_check_duplicate_active_service()
RETURNS TRIGGER AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM contract_services
        WHERE contract_id = NEW.contract_id
          AND service_id = NEW.service_id
          AND deactivated_at IS NULL
    ) THEN
        RAISE EXCEPTION
            'Услуга % уже активна на договоре %', NEW.service_id, NEW.contract_id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_duplicate_active_service
BEFORE INSERT ON contract_services
FOR EACH ROW EXECUTE FUNCTION fn_check_duplicate_active_service();
