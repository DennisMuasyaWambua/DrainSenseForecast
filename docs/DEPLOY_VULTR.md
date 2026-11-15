# Deploying DrainSense to Vultr

Every push to `main` tests the code, builds the `drainsense-api` (FastAPI) and `drainsense-web`
(Next.js desk) images, pushes them to GHCR, and deploys them to one Vultr instance over SSH.

```
GitHub Actions ──push──▶ ghcr.io/<owner>/drainsense-{api,web}:<sha>
      │ ssh
      ▼
Vultr instance  /opt/drainsense  (Compose project "drainsense")
  caddy :80/:443  ── /api/*, /docs, /redoc, /openapi.json ──▶ drainsense-api:8000
                  └─ everything else ─────────────────────▶ drainsense-web:3000
```

Caddy is the only container with host ports and gets a Let's Encrypt certificate on its own. With
no domain, the site is `https://drainsense.<instance-ip>.sslip.io` (sslip.io resolves that name to
the IP, so no DNS record is needed).

Files: `deploy/vultr/` (`docker-compose.yml`, `caddy/Caddyfile`, `remote-deploy.sh`, `bootstrap.sh`)
and the `deploy` job in `.github/workflows/ci.yml`.

## One-time setup

### 1. Create the instance

Vultr console → Deploy → **Cloud Compute**, x86 (Regular or High Performance), **Ubuntu 24.04**.
1 vCPU / 2 GB is comfortable; 1 GB works (bootstrap adds swap). Add your own SSH key for root.
Note the public IPv4.

### 2. Make a deploy key for GitHub Actions

```bash
ssh-keygen -t ed25519 -N '' -C drainsense-github-actions -f ~/.ssh/drainsense_deploy
```

### 3. Bootstrap the instance (Docker, `deploy` user, firewall, swap)

```bash
IP=203.0.113.7   # your instance
ssh root@$IP 'bash -s' -- "$(cat ~/.ssh/drainsense_deploy.pub)" < deploy/vultr/bootstrap.sh
```

This opens 80/443 in ufw. If you also use a **Vultr Firewall Group**, allow TCP 22, 80, 443 and
UDP 443 there too.

### 4. Add the GitHub secrets

Repository → Settings → Secrets and variables → Actions → **Secrets**:

| Secret | Value |
|---|---|
| `VULTR_HOST` | the instance's public IPv4 |
| `VULTR_USER` | `deploy` |
| `VULTR_SSH_KEY` | the whole contents of `~/.ssh/drainsense_deploy` (the private key) |
| `VULTR_KNOWN_HOSTS` | recommended: output of `ssh-keyscan $IP` |
| `VULTR_SSH_PORT` | optional, default 22 |

With the GitHub CLI:

```bash
gh secret set VULTR_HOST --body "$IP"
gh secret set VULTR_USER --body deploy
gh secret set VULTR_SSH_KEY < ~/.ssh/drainsense_deploy
ssh-keyscan "$IP" 2>/dev/null | gh secret set VULTR_KNOWN_HOSTS
```

Optional repository **variables**:

- `DRAINSENSE_SITE_ADDRESS`: your own hostname (e.g. `drainsense.example.org`). Point an A record at
  the instance first. Without it the site is `drainsense.<VULTR_HOST>.sslip.io`.
- `CARTO_BASEMAPS_KEY`: CARTO basemaps key baked into the desk (public, not a secret).

### 5. Deploy

Push to `main`, or Actions → ci → **Run workflow** on `main`. The deploy job prints the URL and
smoke-tests `/api/v1/health`, `/` and `/docs`. The first run waits for the certificate.

## What a deploy does

1. Uploads `deploy/vultr/` and a fresh `.env` (image tags and site address) to `/opt/drainsense`.
2. `remote-deploy.sh`: logs in to GHCR with the job's short-lived token, pulls, runs
   `docker compose up -d`, and waits up to two minutes for the API and the desk to be healthy.
   If they aren't, it starts the previous images (`.env.previous`) again and fails the job.
3. Reloads Caddy (it validates the Caddyfile first and keeps the old config on error).

The SQLite drainage log (`drainsense_api-data`) and Caddy's certificates (`drainsense_caddy-data`)
are Docker volumes and survive redeploys.

## Operating it

```bash
ssh deploy@$IP
cd /opt/drainsense
docker compose ps
docker compose logs -f --tail 100 drainsense-api drainsense-web caddy
```

**Roll back** to any earlier commit's images: Actions → re-run that commit's workflow, or on the box
edit the two image tags in `.env` and run `docker compose up -d`.

**Back up the drainage log:**

```bash
docker run --rm -v drainsense_api-data:/data -v "$PWD":/out alpine \
  tar -czf /out/drainsense-data-$(date +%F).tgz -C /data .
```

## Manual deploy (no CI)

Build and load the images, then run the same script with the pull skipped:

```bash
docker build -f api/Dockerfile -t drainsense-api:manual .
docker build -t drainsense-web:manual web
docker save drainsense-api:manual drainsense-web:manual | gzip | ssh deploy@$IP 'gunzip | docker load'
scp -r deploy/vultr/docker-compose.yml deploy/vultr/remote-deploy.sh deploy/vultr/caddy deploy@$IP:/opt/drainsense/
ssh deploy@$IP "cd /opt/drainsense && printf 'DRAINSENSE_API_IMAGE=drainsense-api:manual\nDRAINSENSE_WEB_IMAGE=drainsense-web:manual\nDRAINSENSE_SITE_ADDRESS=drainsense.$IP.sslip.io\n' > .env \
  && DRAINSENSE_LOCAL_IMAGES=1 bash remote-deploy.sh none < /dev/null"
```
