#!/bin/bash
# Gunluk veritabani yedegi + offsite kopya. Cron'dan calisir. (infra#1)
#
# NE YEDEKLENIYOR, NE YEDEKLENMIYOR
#   aqi_db       TAMAMI. Bu sistemdeki tek telafisi olmayan veri. WAQI gecmise donuk olcum
#                VERMIYOR -- denendi, `date` / `from-to` / `history` parametrelerinin ucu de
#                yalnizca anlik degeri donduruyor. Kaydedilmeyen an bir daha elde edilemez.
#
#   energy_demo  households_marmara'nin VERISI HARIC (semasi kaliyor, --exclude-table-data).
#                O tablo 2283 MB, yani energy_demo'nun neredeyse tamami, ve zaman serisi degil:
#                8.529.528 satirlik statik uretim ciktisi. outdoor-airq-synthetic-data
#                deposundan deterministik uretilebiliyor (SEED=20260727 git'te sabit, TUIK
#                girdileri git'te, src/validate.py #11 iki kez uretip sha256 karsilastiriyor).
#
# Sonuc: gunluk dosyalar ~19 MB (aqi_db 8.3 + energy_demo 11). Sikistirilmamis tablo boyutlari
# ~233 MB, custom format onu bu seviyeye indiriyor.
#
# households_marmara HIC alinmiyor degil, BIR KEZ aliniyor: yeniden uretilebilirlik CANLI bir
# bagimlilik (uretim hattinin calisir kalmasi gerekir), dump ise atil bir dosya. Kurtarma
# baski altinda tek komut olsun diye bir kopyasi duruyor.
set -euo pipefail

CORE_DIR="${CORE_DIR:-/work/outdoor-airq/outdoor-airq-core}"
HEDEF="${YEDEK_DIZINI:-/work/ortak/yedek}"
SAKLAMA_GUN="${SAKLAMA_GUN:-7}"
RCLONE="${RCLONE:-$HOME/.local/bin/rclone}"
UZAK="${YEDEK_UZAK:-}"

DAMGA="$(date +%Y%m%d-%H%M)"
mkdir -p "$HEDEF"

log() { echo "[$(date '+%F %T')] $*"; }

# Parola gerekmiyor: konteyner icinden yerel soket uzerinden baglaniliyor ve postgres imaji
# yerel baglantilara guveniyor. Betikte hicbir sir tutulmuyor.
sorgu() { docker compose -f "$CORE_DIR/docker-compose.yml" exec -T timescaledb \
              psql -U outdoorairq -d "$1" -tAc "$2" | tr -d ' \r'; }

dump() {   # $1=veritabani  $2=cikti  $3+=ek pg_dump argumanlari
    local db="$1" cikti="$2"; shift 2
    docker compose -f "$CORE_DIR/docker-compose.yml" exec -T timescaledb \
        pg_dump -U outdoorairq -Fc "$@" "$db" > "$cikti.tmp"
    # Once .tmp'ye yazip sonra tasiyoruz: cron ortasinda kesilirse yarim dosya "yedek" gibi durmasin.
    mv "$cikti.tmp" "$cikti"
}

# Dump'in yanina sayim dosyasi (.meta) yaziyoruz. SEBEBI: dogrulama, karsilastirma tabanini
# CANLI veritabanindan okursa yanlis alarm uretir -- cron'da dump 03:00'te, dogrulama 04:00'te
# calisiyor ve arada tabloya ~88 satir daha giriyor (olculdu: saatte 87-89). Sayilar esit
# cikmaz, betik "YEDEK BOZUK" der, oysa yedek saglamdir. Haftada bir yanlis alarm veren kontrol
# birkac hafta icinde gormezden gelinir ve o noktadan sonra kimsenin bakmadigi bir kontrol
# kalir -- yani sessiz bozukluk riskini kapatmak icin yazilan sey gurultuyle ayni yere cikar.
#
# ONCE ve SONRA sayiyoruz, tek bir sayi degil ARALIK yaziyoruz: pg_dump baslangicta bir anlik
# goruntu aliyor ve o goruntunun tam olarak hangi satirlari icerdigini disaridan bilemeyiz.
# Kesin olan su: dump'taki satir sayisi, dump'tan hemen ONCEKI ile hemen SONRAKI sayim
# arasindadir. Dogrulama bu araliga bakiyor. Yazim olmayan anlarda iki sayi zaten esit oluyor.
meta_yaz() {   # $1=meta dosyasi  $2=once  $3=sonra  $4=hypertable  $5=aciklama
    printf 'once=%s\nsonra=%s\nhypertable=%s\naciklama=%s\n' "$2" "$3" "$4" "$5" > "$1"
}

log "yedek basliyor -> $HEDEF"

# ---- aqi_db ----
a_once=$(sorgu aqi_db "SELECT count(*) FROM raw_readings")
a_ht=$(sorgu aqi_db "SELECT count(*) FROM timescaledb_information.hypertables")
dump aqi_db "$HEDEF/aqi_db-$DAMGA.dump"
a_sonra=$(sorgu aqi_db "SELECT count(*) FROM raw_readings")
meta_yaz "$HEDEF/aqi_db-$DAMGA.dump.meta" "$a_once" "$a_sonra" "$a_ht" "raw_readings"
log "aqi_db: raw_readings $a_once..$a_sonra, $a_ht hypertable"

# ---- energy_demo ----
# households_marmara'nin VERISI disarida; semasi dump'ta var. Dogrulama bu farki ayrica
# kontrol ediyor (tablo var olmali, icinde 0 satir olmali) -- kendine ozgu hata bicimi olan
# ayri bir geri yukleme yolu bu.
e_once=$(sorgu energy_demo "SELECT count(*) FROM electricity_readings")
e_ht=$(sorgu energy_demo "SELECT count(*) FROM timescaledb_information.hypertables")
dump energy_demo "$HEDEF/energy_demo-$DAMGA.dump" --exclude-table-data=households_marmara
e_sonra=$(sorgu energy_demo "SELECT count(*) FROM electricity_readings")
meta_yaz "$HEDEF/energy_demo-$DAMGA.dump.meta" "$e_once" "$e_sonra" "$e_ht" "electricity_readings"
log "energy_demo: electricity_readings $e_once..$e_sonra, $e_ht hypertable"

# ---- households_marmara (statik, tek sefer) ----
if [ ! -f "$HEDEF/households_marmara.dump" ]; then
    log "households_marmara ilk kez yedekleniyor (statik, tek sefer)"
    h=$(sorgu energy_demo "SELECT count(*) FROM households_marmara")
    dump energy_demo "$HEDEF/households_marmara.dump" --table=households_marmara
    meta_yaz "$HEDEF/households_marmara.dump.meta" "$h" "$h" "0" "households_marmara"
fi

# Saklama. households_marmara.dump damgasiz oldugu icin bu desenlere uymuyor, kazara silinmiyor.
find "$HEDEF" -name "aqi_db-*.dump*"      -mtime "+$SAKLAMA_GUN" -delete
find "$HEDEF" -name "energy_demo-*.dump*" -mtime "+$SAKLAMA_GUN" -delete

# ---- Offsite ----
# Kimlik yoksa sessizce degil GURULTULU atlaniyor: "yedek var" sanip ayni diskte durmak,
# hic yedek olmamasindan daha tehlikeli.
if [ -z "$UZAK" ]; then
    log "UYARI: YEDEK_UZAK tanimsiz -> OFFSITE YOK."
    log "UYARI: Dosyalar veritabaniyla AYNI diskte. 'docker compose down -v' ve volume"
    log "UYARI: silinmesine karsi korur, DISK/HOST KAYBINA KARSI KORUMAZ."
elif [ ! -x "$RCLONE" ]; then
    log "UYARI: rclone bulunamadi ($RCLONE) -> offsite atlandi."
else
    # `copy`, `sync` DEGIL -- bilincli. sync uzaktakini yereldekine esitler; yerel dizin
    # silinir ya da bozulursa UZAKTAKI YEDEKLERI DE SILER, yani felaket anini felakete
    # cevirir. copy yalnizca ekler. Bedeli: uzakta biriken eski dosyalar hic silinmez;
    # budama B2/S3 tarafinda bir yasam dongusu kuraliyla yapilmali (or. 30 gun sonra sil).
    log "offsite yukleniyor -> $UZAK"
    "$RCLONE" copy "$HEDEF" "$UZAK" --include "*.dump" --include "*.meta" --stats-one-line
    log "offsite tamam"
fi

log "bitti:"
# `|| true`: dump hic olusmadiysa glob eslesmez, `ls` 2 doner ve pipefail+set -e yuzunden
# betik bu son satirda hatayla cikardi -- cron yedegi basarisiz sayardi.
(ls -lh "$HEDEF"/*.dump 2>/dev/null || true) | awk '{printf "    %-44s %s\n", $9, $5}'
