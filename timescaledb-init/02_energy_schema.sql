-- energy_demo schema, generated from ~/energy-demo (Flink job sinks + db_households.csv)
CREATE DATABASE energy_demo;

\c energy_demo

CREATE EXTENSION IF NOT EXISTS timescaledb;

CREATE TABLE IF NOT EXISTS households (
    id SERIAL PRIMARY KEY,
    household_code VARCHAR(20) NOT NULL UNIQUE,
    description TEXT,
    person_count INTEGER,
    home_type VARCHAR(50),
    district VARCHAR(100),
    neighborhood VARCHAR(100),
    latitude DOUBLE PRECISION,
    longitude DOUBLE PRECISION,
    has_ac BOOLEAN,
    has_electric_oven BOOLEAN,
    has_gas_boiler BOOLEAN,
    washing_machine_freq_days INTEGER,
    dishwasher_freq_days INTEGER,
    daytime_occupancy_rate NUMERIC(4, 2),
    evening_occupancy_rate NUMERIC(4, 2),
    daily_shower_count INTEGER,
    daily_cooking_sessions INTEGER
);

CREATE TABLE IF NOT EXISTS electricity_readings (
    id BIGSERIAL,
    household_id INTEGER NOT NULL REFERENCES households(id) ON DELETE CASCADE,
    measured_at TIMESTAMP NOT NULL,
    device VARCHAR(50),
    consumption_kwh NUMERIC(10, 4),
    temperature_c NUMERIC(5, 2),
    PRIMARY KEY (id, measured_at)
);

CREATE TABLE IF NOT EXISTS gas_readings (
    id BIGSERIAL,
    household_id INTEGER NOT NULL REFERENCES households(id) ON DELETE CASCADE,
    measured_at TIMESTAMP NOT NULL,
    usage_type VARCHAR(50),
    consumption_m3 NUMERIC(10, 4),
    PRIMARY KEY (id, measured_at)
);

-- flink-job's WindowAggregateSink writes here; the sink no longer creates the table itself
CREATE TABLE IF NOT EXISTS energy_window_aggregates (
    id SERIAL PRIMARY KEY,
    household_id INTEGER NOT NULL REFERENCES households(id) ON DELETE CASCADE,
    metric_key VARCHAR(50) NOT NULL,
    reading_type VARCHAR(11) NOT NULL,
    window_start TIMESTAMP NOT NULL,
    window_end TIMESTAMP NOT NULL,
    sum_consumption NUMERIC(10, 4) NOT NULL,
    avg_consumption NUMERIC(10, 4) NOT NULL,
    sample_count INTEGER NOT NULL,
    created_at TIMESTAMP DEFAULT now()
);

-- flink-job's AnomalySink writes here; the sink no longer creates the table itself
CREATE TABLE IF NOT EXISTS energy_anomalies (
    id SERIAL PRIMARY KEY,
    household_id INTEGER NOT NULL REFERENCES households(id) ON DELETE CASCADE,
    metric_key VARCHAR(50) NOT NULL,
    reading_type VARCHAR(11) NOT NULL,
    measured_at TIMESTAMP NOT NULL,
    actual_value NUMERIC(10, 4) NOT NULL,
    expected_value NUMERIC(10, 4) NOT NULL,
    deviation_pct NUMERIC(6, 2) NOT NULL,
    created_at TIMESTAMP DEFAULT now()
);

SELECT create_hypertable('electricity_readings', 'measured_at', if_not_exists => TRUE);
SELECT create_hypertable('gas_readings', 'measured_at', if_not_exists => TRUE);

-- households seed: energy/publisher/publisher.py'deki HOUSEHOLDS listesiyle birebir aynı.
--
-- Gerekçe: ElectricityReadingSink/GasReadingSink gelen her okumanın household_code'unu bu
-- tabloda arıyor ve bulamazsa "Unknown household 'HANE_00X', skipping" deyip atıyor. Tablo
-- eskiden yalnızca energy/load_households.py ile dolduruluyordu; o script'in beklediği
-- db_households.csv repoda bulunmadığı için her temiz kurulumda tablo boş kalıyor ve enerji
-- hattı sessizce hiç veri yazmıyordu. Bu seed ile demo kutudan çıktığı gibi çalışıyor.
--
-- Zengin alanlar (ilçe, konum, cihaz sahipliği vb.) burada NULL; gerçek db_households.csv
-- eldeyse load_households.py bu satırları ON CONFLICT ... DO UPDATE ile zenginleştirir.
INSERT INTO households (household_code, description, person_count, has_ac) VALUES
    ('HANE_001', 'Demo hane 1', 2, FALSE),
    ('HANE_002', 'Demo hane 2', 4, TRUE),
    ('HANE_003', 'Demo hane 3', 1, FALSE),
    ('HANE_004', 'Demo hane 4', 5, TRUE),
    ('HANE_005', 'Demo hane 5', 3, FALSE)
ON CONFLICT (household_code) DO NOTHING;
