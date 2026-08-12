#!/bin/bash
# Grafana icin SALT OKUNUR veritabani rolu.
#
# Neden ayri bir rol: Grafana'da Editor/Admin yetkisi olan herkes Explore ekranindan
# SERBEST SQL calistirabiliyor. Veri kaynagi veritabani sahibiyle baglansaydi, panolar
# icin verilen bir Grafana parolasi `DROP TABLE raw_readings` yetkisine donusurdu.
#
# Neden .sh, .sql degil: parola env'den okunuyor ve sirlarin dosyaya yazilmamasi gerekiyor.
# Postgres imajinin entrypoint'i /docker-entrypoint-initdb.d altindaki .sh dosyalarini da
# calistirir. Numara 03: 01 (aqi semasi) ve 02 (energy semasi) sonrasi kosmali, cunku
# GRANT SELECT ON ALL TABLES var olan tablolara uygulanir.
#
# DIKKAT: init betikleri YALNIZ BOS VOLUME'DE calisir. Mevcut bir kurulumda rolu elle
# olusturmak gerekir (asagidaki SQL'in aynisi). Bu, core#2'nin (Alembic yok) bilinen
# sonucu; sema gocu yolu acildiginda buraya da tasinabilir.
set -euo pipefail

if [ -z "${GRAFANA_DB_PASSWORD:-}" ]; then
    echo "03_grafana_ro: GRAFANA_DB_PASSWORD tanimsiz, grafana_ro olusturulmadi."
    echo "03_grafana_ro: (Grafana kullanilmiyorsa bu normal.)"
    exit 0
fi

# Parola SQL'e dogrudan gomulmuyor, psql degiskeni olarak geciyor ve `:'gpw'` ile
# aliniyor. Sebep: `PASSWORD '${...}'` yazilsaydi parolada tek tirnak olan bir kurulumda
# SQL dizesi erken kapanirdi (olculdu: `ab'cd` -> ERROR: unrecognized role option "cd",
# container Exited(3)). psql `:'...'` bicimini kendisi dogru kacirir; dolar-tirnak
# ($$...$$) de calisirdi ama parolada $$ gecerse ayni sorunu uretirdi.
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname aqi_db \
     -v gpw="$GRAFANA_DB_PASSWORD" <<-EOSQL
    CREATE ROLE grafana_ro LOGIN PASSWORD :'gpw';
    GRANT CONNECT ON DATABASE aqi_db TO grafana_ro;
    GRANT USAGE ON SCHEMA public TO grafana_ro;
    GRANT SELECT ON ALL TABLES IN SCHEMA public TO grafana_ro;
    -- Sonradan olusan tablolar da (yeni hypertable, chunk'lar) otomatik okunabilsin:
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO grafana_ro;
EOSQL

echo "03_grafana_ro: grafana_ro rolu olusturuldu (yalniz SELECT)."
