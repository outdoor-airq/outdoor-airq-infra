#!/bin/bash
# Yedekleri GERCEKTEN geri yukleyerek dogrular. (infra#1)
#
# NEDEN GEREKLI: bozuk bir yedek, ihtiyac duyulana kadar saglikli gorunur. Dosya olusur,
# boyutu makul durur, `ls` ile bakan memnun olur -- ve kurtarma gunu ise yaramaz. Tek
# guvenilir kontrol geri yukleyip saymaktir.
#
# CIKIS KODUNA GUVENILMIYOR: kurulum sirasinda pg_restore CIKIS KODU 0 dondururken
# "errors ignored on restore: 816" yazdi ve veri hic gelmedi. Belirleyici olan sayilardir.
#
# TIMESCALEDB TUZAGI: duz `pg_restore` calisir gibi gorunur ama hypertable'lar sessizce DUZ
# TABLOYA doner; hata mesajlari akis icinde kaybolur ve sorun aylar sonra performans olarak
# ortaya cikar. Dogru sira pre_restore -> pg_restore -> post_restore ve betik SONUCU da
# dogruluyor: hypertable sayisi tutmazsa hata verir.
#
# KARSILASTIRMA TABANI CANLI DB DEGIL, dump'in yanindaki .meta dosyasidir. Canli DB'den
# okunsaydi her hafta yanlis alarm cikardi: cron'da dump 03:00'te, dogrulama 04:00'te
# calisiyor ve arada tabloya ~88 satir giriyor. .meta, dump aninda alinan ONCE/SONRA
# sayimlarini tutuyor; dump'taki gercek sayi bu ikisinin arasindadir.
#
# Gecici bir konteynerde calisir; calisan sisteme dokunmaz.
set -euo pipefail

HEDEF="${YEDEK_DIZINI:-/work/ortak/yedek}"
IMAJ="${TS_IMAJ:-timescale/timescaledb:latest-pg16}"
CORE_DIR="${CORE_DIR:-/work/outdoor-airq/outdoor-airq-core}"
# households_marmara.dump 108 MB / 8.5 milyon satir; haftalik cron'da her hafta geri yuklemek
# gereksiz yuk, cunku dosya DEGISMIYOR (statik tablo, tek sefer aliniyor). Bir kez dogrulanmasi
# yeterli. DOGRULA_STATIK=1 ile istege bagli calistirilir.
DOGRULA_STATIK="${DOGRULA_STATIK:-0}"

log() { echo "[$(date '+%F %T')] $*"; }
hata_toplam=0

dogrula() {   # $1=dump yolu  $2=sayilacak tablo  $3=ek kontrol SQL (bos olabilir)  $4=beklenen ek deger
    local dump="$1" tablo="$2" ek_sql="${3:-}" ek_bek="${4:-}"
    local kap="yedek-dogrula-$$-$RANDOM"
    local meta="$dump.meta"

    log "--- $(basename "$dump") ($(du -h "$dump" | cut -f1))"

    local once sonra ht_bek
    if [ -f "$meta" ]; then
        once=$(grep '^once='       "$meta" | cut -d= -f2)
        sonra=$(grep '^sonra='     "$meta" | cut -d= -f2)
        ht_bek=$(grep '^hypertable=' "$meta" | cut -d= -f2)
    else
        # .meta yoksa canliya dusuyoruz ama bunun yanlis alarm uretebilecegini SOYLUYORUZ.
        log "  UYARI: $meta yok -> taban canli DB'den aliniyor; dump ile arasinda gecen surede"
        log "  UYARI: yazilan satirlar YANLIS ALARM uretebilir."
        local db="aqi_db"; [[ "$(basename "$dump")" == energy_demo* ]] && db="energy_demo"
        once=$(docker compose -f "$CORE_DIR/docker-compose.yml" exec -T timescaledb \
               psql -U outdoorairq -d "$db" -tAc "SELECT count(*) FROM $tablo" | tr -d ' \r')
        sonra="$once"
        ht_bek=$(docker compose -f "$CORE_DIR/docker-compose.yml" exec -T timescaledb \
               psql -U outdoorairq -d "$db" -tAc "SELECT count(*) FROM timescaledb_information.hypertables" | tr -d ' \r')
    fi

    docker run -d --name "$kap" -e POSTGRES_PASSWORD=dogrulama -e POSTGRES_DB=geri "$IMAJ" >/dev/null
    # -h 127.0.0.1 SART, unix soketi DEGIL. Postgres imajinin entrypoint'i sunucuyu IKI KEZ
    # baslatiyor: once init icin gecici bir tanesi (listen_addresses='' ile, yani yalniz soket),
    # sonra onu KAPATIP gercegini aciyor. Soket uzerinden yapilan kontrol gecici sunucuya
    # baglanip "hazir" diyor ve geri yukleme ortasinda baglanti dusuyor -- yasandi.
    local i
    for i in $(seq 1 40); do
        docker exec "$kap" pg_isready -h 127.0.0.1 -U postgres -d geri >/dev/null 2>&1 && break
        sleep 2
    done
    if ! docker exec "$kap" pg_isready -h 127.0.0.1 -U postgres -d geri >/dev/null 2>&1; then
        log "  BASARISIZ: gecici veritabani ayaga kalkmadi"
        docker rm -f "$kap" >/dev/null 2>&1; hata_toplam=$((hata_toplam+1)); return
    fi
    sleep 3

    docker exec "$kap" psql -U postgres -d geri -q -c "CREATE EXTENSION IF NOT EXISTS timescaledb;" >/dev/null
    docker exec "$kap" psql -U postgres -d geri -q -c "SELECT timescaledb_pre_restore();" >/dev/null
    docker exec -i "$kap" pg_restore -U postgres -d geri --no-owner --no-privileges \
        > "/tmp/restore-$kap.log" 2>&1 < "$dump" || true
    docker exec "$kap" psql -U postgres -d geri -q -c "SELECT timescaledb_post_restore();" >/dev/null

    local geri_satir geri_ht
    geri_satir=$(docker exec "$kap" psql -U postgres -d geri -tAc "SELECT count(*) FROM $tablo" 2>/dev/null | tr -d ' \r')
    geri_ht=$(docker exec "$kap" psql -U postgres -d geri -tAc \
              "SELECT count(*) FROM timescaledb_information.hypertables" 2>/dev/null | tr -d ' \r')

    local yerel=0
    if [ -z "${geri_satir:-}" ] || [ "${geri_satir:-x}" = "x" ]; then
        echo "  BASARISIZ: $tablo okunamadi (geri yukleme basarisiz)"; yerel=1
    elif [ "$geri_satir" -lt "$once" ] || [ "$geri_satir" -gt "$sonra" ]; then
        echo "  BASARISIZ: $tablo=$geri_satir, beklenen aralik $once..$sonra"; yerel=1
    else
        printf "  %-30s %s (beklenen %s..%s) OK\n" "$tablo" "$geri_satir" "$once" "$sonra"
    fi
    if [ "${geri_ht:-0}" != "$ht_bek" ]; then
        echo "  BASARISIZ: hypertable=$geri_ht, beklenen $ht_bek"; yerel=1
    else
        printf "  %-30s %s OK\n" "hypertable" "$geri_ht"
    fi
    # Asil tuzak: veri gelir ama hypertable duz tabloya donerse yukaridaki esitlik de kacar;
    # yine de sifir durumunu ayrica soyluyoruz ki mesaj net olsun.
    if [ "$ht_bek" -gt 0 ] && [ "${geri_ht:-0}" -eq 0 ]; then
        echo "  BASARISIZ: hic hypertable yok -- duz tabloya donmus"; yerel=1
    fi

    # energy_demo'ya ozel: --exclude-table-data yolunun kendine ozgu hata bicimi var.
    # Tablo VAR OLMALI ama icinde 0 satir olmali. Semanin da gelmedigi durum ayri bir hata.
    if [ -n "$ek_sql" ]; then
        local ek; ek=$(docker exec "$kap" psql -U postgres -d geri -tAc "$ek_sql" 2>/dev/null | tr -d ' \r')
        if [ "${ek:-yok}" != "$ek_bek" ]; then
            echo "  BASARISIZ: ek kontrol=$ek, beklenen $ek_bek"; yerel=1
        else
            printf "  %-30s %s OK\n" "households_marmara (bos, sema var)" "$ek"
        fi
    fi

    [ "$yerel" -eq 0 ] && log "  SAGLAM" || { log "  BOZUK -- log: /tmp/restore-$kap.log"; hata_toplam=$((hata_toplam+yerel)); }
    docker rm -f "$kap" >/dev/null 2>&1
}

# `|| true` SART. set -euo pipefail altinda glob eslesmezse `ls` 2 donuyor, pipefail bunu
# boru hattina tasiyor ve set -e betigi ORACIKTA olduruyor -- `2>/dev/null` yalnizca mesaji
# susturuyor, cikis kodunu degil. Sonucu: betik tek satir yazmadan cikiyordu (olculdu: cikis
# kodu 2, sifir cikti) ve asagidaki "dump bulunamadi" mesaji HIC calismiyordu. Cron ciktisi
# log'a gittigi icin bu, log'a bos satir dusmesi yani "dogrulama kostu, sorun yok" gibi
# okunmasi demekti -- tam da bu betigin kapatmak icin yazildigi desen.
# Ne zaman vururdu: ilk kosuda (henuz energy_demo dump'i yokken) ya da yedek dizini bosken.
aqi=$( (ls -t "$HEDEF"/aqi_db-*.dump      2>/dev/null || true) | head -1 )
ene=$( (ls -t "$HEDEF"/energy_demo-*.dump 2>/dev/null || true) | head -1 )
[ -n "$aqi" ] || { echo "HATA: aqi_db dump'i bulunamadi ($HEDEF)"; exit 1; }

dogrula "$aqi" "raw_readings"
[ -n "$ene" ] && dogrula "$ene" "electricity_readings" \
    "SELECT count(*) FROM households_marmara" "0" \
    || log "UYARI: energy_demo dump'i yok, dogrulanmadi"

if [ "$DOGRULA_STATIK" = "1" ] && [ -f "$HEDEF/households_marmara.dump" ]; then
    dogrula "$HEDEF/households_marmara.dump" "households_marmara"
fi

echo
[ "$hata_toplam" -eq 0 ] && log "TUM YEDEKLER SAGLAM" || log "$hata_toplam DOGRULAMA BASARISIZ"
exit $([ "$hata_toplam" -eq 0 ] && echo 0 || echo 1)
