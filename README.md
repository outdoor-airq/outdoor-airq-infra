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

## Gerekli secrets

| Nerede | Secret | Ne için |
|---|---|---|
| Bu repo → Settings → Secrets → Actions | `DEPLOY_HOST`, `DEPLOY_USER`, `DEPLOY_SSH_KEY` | Sunucuya SSH ile rollout |
| `core` ve `synthetic-data` repoları | `INFRA_REPO_PAT` | Buraya `repository_dispatch` (repo scope'lu PAT) |
| Sunucu | `read:packages` PAT | `docker login ghcr.io` (yalnız pull) |

## Bilinen açık işler

Deploy'u bloklamaz ama prod öncesi kapatılmalı — ayrıntı için `deploy-backlog.md`:

- Otomatik DB yedeği (`pg_dump` + offsite + restore testi). Şu an tek volume, yedek yok.
- Monitoring/alerting + backend'e adanmış `/health` endpoint'i.
- Alembic migration baseline — init SQL yalnız boş volume'da çalışır, şema göçü yolu yok.
- Backend CORS'u `ALLOWED_ORIGINS` env'inden okumuyor (compose'da tanımlı ama etkisiz).
- MQTT `allow_anonymous true` — `password_file` ile sertleştirilmeli.
- VPS boyutu ≥4 vCPU / 8 GB (Flink TaskManager Metaspace OOM geçmişi var).
