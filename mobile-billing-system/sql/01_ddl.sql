-- ============================================================
-- Биллинговая система оператора мобильной связи "ТелекомСвязь"
-- Учебный проект: курс "Базы данных", ИТМО, ФТМИ
-- ============================================================

-- ============================================================
-- 1. СПРАВОЧНИК АБОНЕНТОВ
-- ============================================================
CREATE TABLE subscribers (
    subscriber_id     SERIAL PRIMARY KEY,
    last_name         VARCHAR(100) NOT NULL,
    first_name        VARCHAR(100) NOT NULL,
    middle_name       VARCHAR(100),
    passport          VARCHAR(11) NOT NULL,
    birth_date        DATE NOT NULL,
    phone_contact     VARCHAR(20),
    email             VARCHAR(150),
    reg_date          DATE NOT NULL DEFAULT CURRENT_DATE,

    CONSTRAINT chk_subscriber_passport
        CHECK (passport ~ '^\d{4} \d{6}$'),
    CONSTRAINT chk_subscriber_email
        CHECK (email IS NULL OR email ~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'),
    CONSTRAINT chk_subscriber_birth
        CHECK (birth_date <= CURRENT_DATE - INTERVAL '14 years')
);

-- ============================================================
-- 2. ТАРИФНЫЕ ПЛАНЫ (с поддержкой иерархии: тариф может быть
--    основан на "родительском" тарифе — для рекурсивного запроса)
-- ============================================================
CREATE TABLE tariff_plans (
    tariff_id         SERIAL PRIMARY KEY,
    parent_tariff_id  INT REFERENCES tariff_plans(tariff_id),
    name              VARCHAR(100) NOT NULL UNIQUE,
    monthly_fee       NUMERIC(10,2) NOT NULL,
    included_minutes  INT NOT NULL DEFAULT 0,
    included_sms      INT NOT NULL DEFAULT 0,
    included_gb       NUMERIC(6,2) NOT NULL DEFAULT 0,
    price_per_minute  NUMERIC(6,2) NOT NULL,
    price_per_sms     NUMERIC(6,2) NOT NULL,
    price_per_gb      NUMERIC(6,2) NOT NULL,
    is_active         BOOLEAN NOT NULL DEFAULT TRUE,

    CONSTRAINT chk_tariff_fee CHECK (monthly_fee >= 0),
    CONSTRAINT chk_tariff_minutes CHECK (included_minutes >= 0),
    CONSTRAINT chk_tariff_sms CHECK (included_sms >= 0),
    CONSTRAINT chk_tariff_gb CHECK (included_gb >= 0)
);

-- ============================================================
-- 3. КАТАЛОГ ДОПОЛНИТЕЛЬНЫХ УСЛУГ
-- ============================================================
CREATE TABLE services (
    service_id        SERIAL PRIMARY KEY,
    name              VARCHAR(150) NOT NULL UNIQUE,
    description       TEXT,
    monthly_price     NUMERIC(10,2) NOT NULL,
    service_type      VARCHAR(30) NOT NULL,

    CONSTRAINT chk_service_price CHECK (monthly_price >= 0),
    CONSTRAINT chk_service_type
        CHECK (service_type IN ('roaming', 'forwarding', 'social_unlimited', 'content', 'other'))
);

-- ============================================================
-- 4. ЗОНЫ РОУМИНГА
-- ============================================================
CREATE TABLE roaming_zones (
    zone_id            SERIAL PRIMARY KEY,
    zone_name          VARCHAR(100) NOT NULL UNIQUE,
    country_group      VARCHAR(100) NOT NULL,
    minute_multiplier  NUMERIC(4,2) NOT NULL DEFAULT 1.0,
    sms_multiplier     NUMERIC(4,2) NOT NULL DEFAULT 1.0,
    gb_multiplier      NUMERIC(4,2) NOT NULL DEFAULT 1.0,

    CONSTRAINT chk_zone_multipliers
        CHECK (minute_multiplier > 0 AND sms_multiplier > 0 AND gb_multiplier > 0)
);

-- ============================================================
-- 5. ДОГОВОРЫ / НОМЕРА АБОНЕНТОВ
-- ============================================================
CREATE TABLE contracts (
    contract_id        SERIAL PRIMARY KEY,
    subscriber_id      INT NOT NULL REFERENCES subscribers(subscriber_id) ON DELETE RESTRICT,
    tariff_id          INT NOT NULL REFERENCES tariff_plans(tariff_id) ON DELETE RESTRICT,
    phone_number       VARCHAR(15) NOT NULL UNIQUE,
    connection_date    DATE NOT NULL DEFAULT CURRENT_DATE,
    status             VARCHAR(20) NOT NULL DEFAULT 'active',
    balance            NUMERIC(12,2) NOT NULL DEFAULT 0,
    credit_limit       NUMERIC(12,2) NOT NULL DEFAULT 0,

    CONSTRAINT chk_contract_status
        CHECK (status IN ('active', 'suspended', 'terminated')),
    CONSTRAINT chk_contract_credit_limit CHECK (credit_limit >= 0),
    CONSTRAINT chk_contract_phone_format
        CHECK (phone_number ~ '^\+7\d{10}$')
);

CREATE INDEX idx_contracts_subscriber ON contracts(subscriber_id);
CREATE INDEX idx_contracts_status ON contracts(status);

-- ============================================================
-- 6. ПОДКЛЮЧЁННЫЕ УСЛУГИ (M:N контракт <-> услуга)
-- ============================================================
CREATE TABLE contract_services (
    contract_service_id  SERIAL PRIMARY KEY,
    contract_id           INT NOT NULL REFERENCES contracts(contract_id) ON DELETE CASCADE,
    service_id            INT NOT NULL REFERENCES services(service_id) ON DELETE RESTRICT,
    activated_at           DATE NOT NULL DEFAULT CURRENT_DATE,
    deactivated_at          DATE,

    CONSTRAINT chk_cs_dates
        CHECK (deactivated_at IS NULL OR deactivated_at >= activated_at),
    CONSTRAINT uq_active_service UNIQUE (contract_id, service_id, activated_at)
);

CREATE INDEX idx_contract_services_contract ON contract_services(contract_id);

-- ============================================================
-- 7. CDR — детальные записи о звонках/SMS/интернет-сессиях
--    Партиционирование по диапазону дат (помесячно)
-- ============================================================
CREATE TABLE cdr (
    cdr_id            BIGSERIAL,
    contract_id       INT NOT NULL REFERENCES contracts(contract_id) ON DELETE RESTRICT,
    record_type       VARCHAR(10) NOT NULL,
    zone_id           INT REFERENCES roaming_zones(zone_id),
    started_at        TIMESTAMP NOT NULL,
    duration_seconds  INT,
    data_volume_mb    NUMERIC(10,2),
    cost              NUMERIC(10,2) NOT NULL DEFAULT 0,

    CONSTRAINT chk_cdr_type CHECK (record_type IN ('call', 'sms', 'data')),
    CONSTRAINT chk_cdr_cost CHECK (cost >= 0),
    PRIMARY KEY (cdr_id, started_at)
) PARTITION BY RANGE (started_at);

-- Партиции по месяцам (на момент учебного периода)
CREATE TABLE cdr_2026_04 PARTITION OF cdr
    FOR VALUES FROM ('2026-04-01') TO ('2026-05-01');
CREATE TABLE cdr_2026_05 PARTITION OF cdr
    FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
CREATE TABLE cdr_2026_06 PARTITION OF cdr
    FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');

CREATE INDEX idx_cdr_contract ON cdr(contract_id);

-- ============================================================
-- 8. СЧЕТА
-- ============================================================
CREATE TABLE invoices (
    invoice_id        SERIAL PRIMARY KEY,
    contract_id       INT NOT NULL REFERENCES contracts(contract_id) ON DELETE RESTRICT,
    period_start      DATE NOT NULL,
    period_end        DATE NOT NULL,
    total_amount      NUMERIC(12,2) NOT NULL DEFAULT 0,
    status            VARCHAR(20) NOT NULL DEFAULT 'issued',
    issued_at         TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    due_date          DATE NOT NULL,

    CONSTRAINT chk_invoice_period CHECK (period_end > period_start),
    CONSTRAINT chk_invoice_status
        CHECK (status IN ('issued', 'paid', 'overdue', 'cancelled')),
    CONSTRAINT chk_invoice_amount CHECK (total_amount >= 0)
);

CREATE INDEX idx_invoices_contract ON invoices(contract_id);

-- ============================================================
-- 9. ДЕТАЛИЗАЦИЯ СЧЁТА
-- ============================================================
CREATE TABLE invoice_items (
    invoice_item_id   SERIAL PRIMARY KEY,
    invoice_id        INT NOT NULL REFERENCES invoices(invoice_id) ON DELETE CASCADE,
    item_type         VARCHAR(30) NOT NULL,
    description       VARCHAR(255) NOT NULL,
    amount            NUMERIC(10,2) NOT NULL,

    CONSTRAINT chk_item_type
        CHECK (item_type IN ('subscription_fee', 'service_fee', 'overage_minutes',
                              'overage_sms', 'overage_data', 'roaming')),
    CONSTRAINT chk_item_amount CHECK (amount >= 0)
);

CREATE INDEX idx_invoice_items_invoice ON invoice_items(invoice_id);

-- ============================================================
-- 10. ПЛАТЕЖИ
-- ============================================================
CREATE TABLE payments (
    payment_id        SERIAL PRIMARY KEY,
    invoice_id        INT REFERENCES invoices(invoice_id) ON DELETE SET NULL,
    contract_id       INT NOT NULL REFERENCES contracts(contract_id) ON DELETE RESTRICT,
    amount            NUMERIC(12,2) NOT NULL,
    payment_method    VARCHAR(20) NOT NULL,
    paid_at           TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT chk_payment_amount CHECK (amount > 0),
    CONSTRAINT chk_payment_method
        CHECK (payment_method IN ('card', 'cash', 'online', 'auto_debit'))
);

CREATE INDEX idx_payments_contract ON payments(contract_id);

-- ============================================================
-- 11. ИСТОРИЯ ИЗМЕНЕНИЙ БАЛАНСА
-- ============================================================
CREATE TABLE balance_transactions (
    transaction_id     SERIAL PRIMARY KEY,
    contract_id        INT NOT NULL REFERENCES contracts(contract_id) ON DELETE RESTRICT,
    transaction_type   VARCHAR(20) NOT NULL,
    amount             NUMERIC(12,2) NOT NULL,
    balance_after      NUMERIC(12,2),
    related_payment_id INT REFERENCES payments(payment_id),
    created_at         TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT chk_transaction_type
        CHECK (transaction_type IN ('top_up', 'charge', 'correction'))
);

CREATE INDEX idx_balance_tx_contract ON balance_transactions(contract_id);
