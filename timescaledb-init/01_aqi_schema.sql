-- aqi_db schema, generated from shared/models.py (SQLAlchemy ORM)
CREATE EXTENSION IF NOT EXISTS timescaledb;

CREATE TABLE IF NOT EXISTS stations (
    id INTEGER PRIMARY KEY,
    name TEXT,
    lat DOUBLE PRECISION,
    lng DOUBLE PRECISION
);

CREATE TABLE IF NOT EXISTS raw_readings (
    id BIGSERIAL,
    station_id INTEGER REFERENCES stations(id),
    station_name TEXT,
    measured_at TIMESTAMPTZ NOT NULL,
    ingested_at TIMESTAMPTZ DEFAULT now(),
    pm25 DOUBLE PRECISION,
    pm10 DOUBLE PRECISION,
    o3 DOUBLE PRECISION,
    no2 DOUBLE PRECISION,
    so2 DOUBLE PRECISION,
    co DOUBLE PRECISION,
    temperature DOUBLE PRECISION,
    humidity DOUBLE PRECISION,
    wind DOUBLE PRECISION,
    aqi INTEGER,
    dominant TEXT,
    raw_payload JSONB,
    PRIMARY KEY (id, measured_at)
);

CREATE TABLE IF NOT EXISTS processed_readings (
    id BIGSERIAL,
    raw_id BIGINT,
    station_id INTEGER,
    measured_at TIMESTAMPTZ NOT NULL,
    computed_aqi INTEGER,
    category TEXT,
    is_anomaly BOOLEAN,
    algo_version TEXT,
    processed_at TIMESTAMPTZ DEFAULT now(),
    PRIMARY KEY (id, measured_at)
);

CREATE TABLE IF NOT EXISTS filtered_readings (
    id BIGSERIAL PRIMARY KEY,
    raw_id BIGINT,
    station_id INTEGER,
    measured_at TIMESTAMPTZ,
    baseline_mean DOUBLE PRECISION,
    baseline_std DOUBLE PRECISION,
    z_score DOUBLE PRECISION,
    is_anomaly BOOLEAN,
    is_valid BOOLEAN,
    validity_notes TEXT,
    algo_version TEXT,
    filtered_at TIMESTAMPTZ DEFAULT now()
);

SELECT create_hypertable('raw_readings', 'measured_at', if_not_exists => TRUE);
SELECT create_hypertable('processed_readings', 'measured_at', if_not_exists => TRUE);

-- required for aqi-flink-job's RawReadingsSink.java ON CONFLICT (station_id, measured_at) DO NOTHING
CREATE UNIQUE INDEX IF NOT EXISTS raw_readings_station_measured_uniq ON raw_readings (station_id, measured_at);

-- aqi-flink-job's WindowAggregateSink writes here; the sink no longer creates the table itself
CREATE TABLE IF NOT EXISTS aqi_window_aggregates (
    id SERIAL,
    station_id INTEGER NOT NULL,
    station_name TEXT,
    window_start TIMESTAMPTZ NOT NULL,
    window_end TIMESTAMPTZ NOT NULL,
    avg_aqi NUMERIC(6, 2) NOT NULL,
    avg_pm25 NUMERIC(6, 2),
    avg_pm10 NUMERIC(6, 2),
    max_aqi INTEGER NOT NULL,
    sample_count INTEGER NOT NULL,
    created_at TIMESTAMPTZ DEFAULT now(),
    -- window_start partition kolonu olduğu için PK'ye dahil edilmeli (TimescaleDB kısıtı)
    PRIMARY KEY (id, window_start)
);

-- aqi-flink-job's AnomalySink writes here; the sink no longer creates the table itself
CREATE TABLE IF NOT EXISTS aqi_anomalies (
    id SERIAL,
    station_id INTEGER NOT NULL,
    station_name TEXT,
    measured_at TIMESTAMPTZ NOT NULL,
    actual_aqi INTEGER NOT NULL,
    expected_aqi NUMERIC(6, 2) NOT NULL,
    deviation_pct NUMERIC(6, 2) NOT NULL,
    severity VARCHAR(8) NOT NULL,
    detected_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- detected_at partition kolonu olduğu için PK'ye dahil edilmeli (TimescaleDB kısıtı)
    PRIMARY KEY (id, detected_at)
);

SELECT create_hypertable('aqi_window_aggregates', 'window_start', if_not_exists => TRUE);
SELECT create_hypertable('aqi_anomalies', 'detected_at', if_not_exists => TRUE);

-- aqi_anomalies (station_id, measured_at): backend'in anomali EXISTS sorgularini (latest/history/
-- calendar, bkz. services/stations.py + readings.py) ve AnomalySink'in idempotent insert'ini
-- (WHERE NOT EXISTS) hizlandirir. NON-UNIQUE: aqi_anomalies detected_at ile partitionlanmis bir
-- hypertable; TimescaleDB unique index'in partition kolonunu (detected_at) icermesini sart kosar,
-- ama tekillik measured_at bazinda gerekir -> unique index ise yaramaz. Tekillik bunun yerine
-- Flink dedup operatoru + idempotent insert ile saglanir.
CREATE INDEX IF NOT EXISTS aqi_anomalies_station_measured_idx
    ON aqi_anomalies (station_id, measured_at);

-- filtered_readings (yalnizca backfill z-score anomalilerini tutar): takvim/history'nin iki-kaynakli
-- anomali birlesimi (bkz. services/stations.py _anomaly_exists_subquery) buraya da EXISTS atiyor.
-- Partial index (WHERE is_anomaly) sadece anomali satirlarini tutar -> sorgu icin tam ortusme.
CREATE INDEX IF NOT EXISTS filtered_readings_station_measured_anom_idx
    ON filtered_readings (station_id, measured_at) WHERE is_anomaly;
