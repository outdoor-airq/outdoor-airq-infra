# outdoor-airq-infra

Prod ortamının dağıtım tanımı. Uygulama kodu burada değil — imajlar
[`outdoor-airq-core`](https://github.com/outdoor-airq/outdoor-airq-core) ve
[`outdoor-airq-synthetic-data`](https://github.com/outdoor-airq/outdoor-airq-synthetic-data)
repolarında derlenip GHCR'ye push edilir, burası yalnızca hangi SHA'nın çalışacağını sabitler.

```
core push → GHCR (SHA tag) → infra'ya repository_dispatch → .env'de SHA güncellenir → rollout
```

## Dosyalar

| | |
|---|---|
| `docker-compose.prod.yml` | Prod servis tanımı. Host'a hiç port açmaz. |
| `.env.example` | Şablon. Gerçek `.env` sunucuda, git'e girmez, izni 600. |
| `timescaledb-init/` | `core/timescaledb/init/` **kopyası** — fresh volume'da şemayı kurar. |
| `mosquitto/config/` | `core/mosquitto/config/` **kopyası**. |
| `.github/workflows/deploy.yml` | `repository_dispatch` ile tetiklenen rollout. |

> **Tek şema kaynağı uyarısı:** `timescaledb-init/` ve `mosquitto/config/` core'dan kopyadır.
> Core'da bu dosyalar değişirse buradaki kopyalar **elle** senkronlanmalı. İleride bir CI adımı
> ya da submodule ile otomatikleştirilebilir.

## İlk kurulum

```bash
git clone https://github.com/outdoor-airq/outdoor-airq-infra.git /opt/outdoor-airq-infra
cd /opt/outdoor-airq-infra
cp .env.example .env && chmod 600 .env    # doldur

# GHCR'den pull edebilmek icin (read:packages izinli, pull-only PAT)
echo "$GHCR_READONLY_PAT" | docker login ghcr.io -u <kullanici> --password-stdin

docker compose -f docker-compose.prod.yml up -d                     # AQI + altyapi + tunnel
docker compose -f docker-compose.prod.yml --profile energy up -d    # ileride enerji de
```

## Ağ ve güvenlik

Sunucuda **hiçbir inbound port açılmaz**. Dış erişim yalnızca `cloudflared` üzerinden:
Cloudflare Zero Trust'ta `api.${DOMAIN}` → `http://backend:8000` ingress'i tanımlanır,
TLS'i Cloudflare terminate eder, origin IP gizli kalır.

Flink Web UI (8081) de kapalıdır; ops erişimi için `ssh -L 8081:localhost:8081 <sunucu>`
ya da Cloudflare Access arkasında ikinci bir hostname.

Frontend Cloudflare Pages'te ayrı yaşar (`app.${DOMAIN}`), `VITE_API_URL=https://api.${DOMAIN}`
**mutlak** adres olmalı ve `public/_redirects` içinde `/* /index.html 200` bulunmalı.

**Firewall:** `cloudflared` yalnızca giden (outbound) bağlantı kurar, hiçbir yeri dinlemez — bu yüzden
sunucuda 80/443 dahil **hiçbir inbound porta gerek yok**. `ufw` ile yalnız SSH açık bırakılır (mümkünse
onu da Cloudflare Access / WARP arkasına al).

## Gerekli secrets

| Nerede | Secret | Ne için |
|---|---|---|
| Bu repo → Settings → Secrets → Actions | `DEPLOY_HOST`, `DEPLOY_USER`, `DEPLOY_SSH_KEY` | Sunucuya SSH ile rollout |
| `core` ve `synthetic-data` repoları | `INFRA_REPO_PAT` | Buraya `repository_dispatch` — yalnız `outdoor-airq-infra`'ya `Contents: write` yetkili **fine-grained** PAT (klasik `repo` scope da çalışır ama gereksiz geniş) |
| Sunucu | `read:packages` PAT | `docker login ghcr.io` (yalnız pull) |

> **⚠️ `INFRA_REPO_PAT` sahibine dikkat:** PAT kişisel bir hesaba bağlıdır. Onu üreten kişi org'dan
> ayrılır ya da token'ın süresi dolarsa, `core`/`synthetic-data` push'unda infra'ya dispatch **sessizce
> durur** — üstelik workflow guard'ı yüzünden build **kırmızı yanmaz**, `::warning::` basıp geçer
> (image'lar GHCR'de hazır kalır, deploy elle yapılır). Kalıcı çözüm: org'a ait bir **GitHub App**
> (installation token kimseye bağlı değil). En azından ayrılmadan önce PAT'ı yeni sorumluya devret ve
> eskisini **revoke** et.

<!-- Açık anchor: "İzleme" başlığının otomatik slug'ı `i̇zleme-infra2` oluyor — `İ` küçültülünce
     `i` + U+0307 (birleşik nokta) üretiyor ve GitHub bunu slug'da koruyor. Düz ASCII `i` ile
     yazılan bağlantı bu id'yi tutturamıyor. Sabit bir id vermek, görünmez bir karakteri
     bağlantının içine gömmekten sağlam. -->
<a id="izleme"></a>

## İzleme (infra#2)

Uygulama stack'inden **ayrı** bir compose dosyası: `monitoring/docker-compose.monitoring.yml`.
İzleme, izlediği şeyle birlikte ölmemeli.

```bash
cd monitoring
docker compose -f docker-compose.monitoring.yml up -d          # dev/kutu
MONITORING_NETWORK=outdoor-airq_aqi-network \
  docker compose -f docker-compose.monitoring.yml up -d         # prod (ağ adı farklı)
```

Arayüz `http://<sunucu>:3001` — kutuda Tailscale üzerinden `http://100.90.66.40:3001`.
İnternete açık değil; Cloudflare Tunnel yalnız 8000/8080/8081'i yayınlıyor.

> **İlk açılışta hemen admin hesabı oluşturun.** Hesap yaratılana kadar kurulum sahipsizdir
> ve tailnet'teki herhangi biri devralabilir.

### Kurulacak monitörler

Uptime Kuma'nın deklaratif config dosyası **yoktur** — monitörler arayüzden tanımlanır ve
`uptime_kuma_data` volume'unda (SQLite) saklanır. Bu yüzden aşağıdaki tablo elle uygulanmalı.
Hepsinde `Retries: 2` önerilir; tek bir başarısız istekte alarm çalmasın.

| Ad | Tip | URL | Aralık | Neyi yakalar |
|---|---|---|---|---|
| `backend-health` | HTTP(s) | `http://backend:8000/health` | 60 sn | **Asıl kontrol.** Veri akışı durursa endpoint 503 döner. |
| `api-public` | HTTP(s) | `https://outdoor-airq-api.arteq.com.tr/health` | 300 sn | Aynı kontrol + Cloudflare Tunnel. Bu kırmızı, `backend-health` yeşilse sorun tunnel'da. |
| `flink-jobmanager` | HTTP(s) | `http://flink-jobmanager:8081/overview` | 60 sn | JobManager'ın kendisi ayakta mı. |
| `frontend-public` | HTTP(s) | `https://outdoor-airq.arteq.com.tr` | 300 sn | Vitrin sayfası servis ediliyor mu. |

**Neden `/health` asıl kontrol:** "servis ayakta mı" sormak yetmiyor — bu projede kayıtlı iki
sessiz ölüm vakasında da servisler ayaktaydı, job `RUNNING` görünüyordu ve dashboard eski
satırlarla **dolu** duruyordu. `/health` son kaydın yaşını döndürür ve eşiği aşınca 503 verir,
yani Uptime Kuma tarafında ekstra kural yazmaya gerek yok: "200 değilse alarm" yeterli.
Eşik varsayılan 3 saat, `HEALTH_STALE_SECONDS` ile değiştirilebilir (gerekçesi
`core/backend/app/services/health.py` içinde).

İsteğe bağlı, daha keskin bir Flink kontrolü — JobManager ayakta ama AQI job'ı düşmüş olabilir.
Uptime Kuma "HTTP(s) - Json Query" tipiyle, `http://flink-jobmanager:8081/jobs/overview`
üzerinde jsonata ifadesi:

```
jobs[name="AQI MQTT to TimescaleDB Job" and state="RUNNING"].state
```

beklenen değer `RUNNING`. (Endpoint'in bu alanları döndürdüğü doğrulandı; ifadenin Uptime Kuma
arayüzündeki davranışı test edilmedi, eklerken bir kez elle deneyin.)

### Bildirim

Settings → Notifications → Setup Notification. **Default enabled** işaretlenirse bütün
monitörlere uygulanır.

- **Telegram** (en hızlısı): @BotFather → `/newbot` → token; bota bir mesaj atıp Uptime
  Kuma'daki "Get chat ID" düğmesiyle chat id alınır.
- **E-posta (SMTP)**: SMTP sunucu/port/kullanıcı/parola gerekir.

Kimlik bilgileri kişiye/kuruma ait olduğu için bu adım repoda tanımlanamaz, arayüzden yapılır.

## Metrik ve görselleştirme (Grafana + Prometheus)

`monitoring/docker-compose.metrics.yml` — Uptime Kuma'dan **ayrı** dosya, çünkü farklı soruyu
cevaplıyorlar ve bağımsız açılıp kapanmaları gerekiyor:

| | Sorusu | Çıktısı |
|---|---|---|
| Uptime Kuma | "ayakta mı?" | evet/hayır, alarm |
| bu yığın | "ne kadar?" | sayılar, eğilim, inceleme |

```bash
cd monitoring
cp .env.example .env && chmod 600 .env    # doldur (aşağıya bak)
docker compose -f docker-compose.metrics.yml up -d
```

`monitoring/.env` **zorunlu**, yoksa compose açılmaz (değişkenler `:?` ile korumalı):

| Değişken | Ne |
|---|---|
| `DB_USER`, `DB_PASSWORD` | Grafana'nın TimescaleDB'ye bağlanması için. `core/.env` ile **aynı** değerler. |
| `GRAFANA_USER`, `GRAFANA_PASSWORD` | Grafana arayüz girişi |

> `GF_SECURITY_ADMIN_PASSWORD` yalnızca **ilk açılışta** uygulanır; sonrasında parola Grafana'nın
> kendi veritabanında yaşar. Sonradan değiştirmek için:
> `docker compose -f docker-compose.metrics.yml exec grafana grafana cli admin reset-admin-password <yeni>`

Arayüzler Tailscale üzerinden: Grafana `:3000`, Prometheus `:9090`. İnternete açık değil.

**Grafana deklaratif kuruluyor** — Uptime Kuma'dan en büyük farkı bu. Veri kaynakları
(`grafana/provisioning/`) ve dashboard'lar (`grafana/dashboards/*.json`) dosyadan geliyor, arayüzden
tıklamaya gerek yok; kurulumun tamamı git'te ve yeniden üretilebilir.

İki dashboard hazır gelir:
- **outdoor-airq — Veri**: doğrudan TimescaleDB'den. Son verinin yaşı, istasyon/ölçüm/anomali
  sayaçları, istasyon bazında AQI zaman serisi, son ölçümler tablosu. Arada exporter yok —
  TimescaleDB düz PostgreSQL olduğu için Grafana canlı tabloya SQL soruyor.
- **outdoor-airq — Makine**: Prometheus + node-exporter.

### ⚠️ Makine metrikleri: neyi ölçtüğüne dikkat

Kurulum üç katmanlı: **Docker → Proxmox LXC (bu kutu) → Proxmox ana makinesi.** `lxcfs`,
`/proc/meminfo` gibi dosyaları **okuyan sürecin cgroup'una göre** üretir. Sonuç:

| Metrik | Kapsamı | Güvenilir mi |
|---|---|---|
| Disk | bu kutu | ✅ gerçek dosya sistemi okunuyor, `df -h` ile doğrulandı |
| Bellek | node-exporter'ın kendi container'ı | ❌ ölçüldü: "7.99 GB boş" derken kutunun gerçeği 3.4 GB'tı |
| CPU / yük | Proxmox ana makinesinin tamamı | ❌ yük 6.17 görünürken kutudaki container'ların toplamı %4'tü |

Bayraklar (`--path.procfs`, `--path.sysfs`) eklendiğinde bellek **toplamı** ve CPU **sayısı**
doğruya oturuyor, ama cgroup kaynaklı sapma bayrakla çözülmüyor — node-exporter'ın LXC'nin kök
cgroup'unda çalışması gerekirdi, Docker içinden mümkün değil.

Panel başlıklarında kapsam açıkça yazılı ve dashboard'un başında uyarı paneli var. Kutunun gerçek
bellek/CPU durumu için `free -h` ve `docker stats`.

### Kapsam dışı bırakılanlar

Uygulamanın **kendi** metrikleri toplanmıyor; ikisi de core'da değişiklik gerektirir:
- **Flink** operatör sayaçları → `FLINK_PROPERTIES`'e PrometheusReporter eklenmeli (core compose değişir)
- **FastAPI** istek süreleri → `prometheus-fastapi-instrumentator` bağımlılığı

Eklenirlerse `prometheus/prometheus.yml`'ye birer `scrape_config` satırı gelir.

## Bilinen açık işler

Deploy'u bloklamaz ama prod öncesi kapatılmalı. Her biri bir GitHub Issue:

- [infra#1](https://github.com/outdoor-airq/outdoor-airq-infra/issues/1) — Otomatik DB yedeği (`pg_dump` + offsite + restore testi). Şu an tek volume, yedek yok.
- [infra#2](https://github.com/outdoor-airq/outdoor-airq-infra/issues/2) — Monitoring/alerting. **Kısmen kapandı:** backend `/health` eklendi (`core` d0fefbf) ve Uptime Kuma ayağa kaldırıldı (bkz. [İzleme](#izleme)). **Kalan:** monitörlerin arayüzden tanımlanması ve bildirim kanalının bağlanması — ikisi de kimlik bilgisi gerektirdiği için elle.
- [infra#3](https://github.com/outdoor-airq/outdoor-airq-infra/issues/3) — MQTT `allow_anonymous true` → `password_file` ile sertleştirme.
- [infra#4](https://github.com/outdoor-airq/outdoor-airq-infra/issues/4) — VPS boyutu ≥4 vCPU / 8 GB (Flink TaskManager Metaspace OOM geçmişi var).
- [core#1](https://github.com/outdoor-airq/outdoor-airq-core/issues/1) — Backend CORS'u `ALLOWED_ORIGINS` env'inden okumuyor (compose'da tanımlı ama etkisiz).
- [core#2](https://github.com/outdoor-airq/outdoor-airq-core/issues/2) — Alembic migration baseline; init SQL yalnız boş volume'da çalışır, şema göçü yolu yok.
