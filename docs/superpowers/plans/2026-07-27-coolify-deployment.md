# Coolify Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a reproducible, production-oriented Coolify Docker Compose deployment for V2Board while preserving the existing local Compose workflow.

**Architecture:** A dedicated `docker-compose.coolify.yml` defines Nginx as the only proxy-facing service and keeps PHP-FPM, MySQL, and Redis on a private network. The existing PHP entrypoint consumes a stable Coolify-provided `APP_KEY`, propagates mail configuration, and retains local fallback behavior.

**Tech Stack:** Docker Compose, Docker, Bash, Nginx, PHP 8.1 FPM, Laravel 8, MySQL 8.0, Redis 7, Coolify

## Global Constraints

- Keep `docker-compose.yml` unchanged for local deployment.
- Do not publish MySQL, Redis, or PHP-FPM ports.
- Do not publish an Nginx host port in the Coolify Compose file.
- Require `APP_URL`, `APP_KEY`, database passwords, Redis password, and administrator credentials.
- Preserve MySQL and Redis data through named volumes.
- Do not add CI/CD, a registry, or managed external services.

---

### Task 1: Add the Coolify Compose Stack

**Files:**
- Create: `docker-compose.coolify.yml`

**Interfaces:**
- Consumes: existing `Dockerfile`, `docker/nginx/Dockerfile`, and service DNS names `php`, `mysql`, and `redis`
- Produces: a Coolify-discoverable Compose stack with proxy-facing service `nginx` on container port 80

- [ ] **Step 1: Verify the Coolify Compose file is absent**

Run:

```powershell
docker compose -f docker-compose.coolify.yml config
```

Expected: FAIL because `docker-compose.coolify.yml` does not exist.

- [ ] **Step 2: Create the minimal Coolify Compose file**

Create `docker-compose.coolify.yml` with:

```yaml
services:
  php:
    build:
      context: .
      dockerfile: Dockerfile
    restart: unless-stopped
    depends_on:
      mysql:
        condition: service_healthy
      redis:
        condition: service_healthy
    environment:
      APP_NAME: ${APP_NAME:-V2Board}
      APP_ENV: production
      APP_DEBUG: "false"
      APP_URL: ${APP_URL:?APP_URL is required}
      APP_KEY: ${APP_KEY:?APP_KEY is required}
      DB_CONNECTION: mysql
      DB_HOST: mysql
      DB_PORT: 3306
      DB_DATABASE: ${DB_DATABASE:-v2board}
      DB_USERNAME: ${DB_USERNAME:-v2board}
      DB_PASSWORD: ${DB_PASSWORD:?DB_PASSWORD is required}
      REDIS_HOST: redis
      REDIS_PORT: 6379
      REDIS_PASSWORD: ${REDIS_PASSWORD:?REDIS_PASSWORD is required}
      CACHE_DRIVER: redis
      SESSION_DRIVER: redis
      QUEUE_CONNECTION: redis
      ADMIN_EMAIL: ${ADMIN_EMAIL:?ADMIN_EMAIL is required}
      ADMIN_PASSWORD: ${ADMIN_PASSWORD:?ADMIN_PASSWORD is required}
      MAIL_DRIVER: ${MAIL_DRIVER:-smtp}
      MAIL_HOST: ${MAIL_HOST:-}
      MAIL_PORT: ${MAIL_PORT:-587}
      MAIL_USERNAME: ${MAIL_USERNAME:-}
      MAIL_PASSWORD: ${MAIL_PASSWORD:-}
      MAIL_ENCRYPTION: ${MAIL_ENCRYPTION:-tls}
      MAIL_FROM_ADDRESS: ${MAIL_FROM_ADDRESS:-}
      MAIL_FROM_NAME: ${MAIL_FROM_NAME:-V2Board}
    healthcheck:
      test: ["CMD-SHELL", "nc -z 127.0.0.1 9000 || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 20
      start_period: 60s
    networks:
      - v2board-net

  nginx:
    build:
      context: .
      dockerfile: docker/nginx/Dockerfile
    restart: unless-stopped
    depends_on:
      php:
        condition: service_healthy
    expose:
      - "80"
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://127.0.0.1/health | grep -q '^ok$'"]
      interval: 15s
      timeout: 5s
      retries: 10
      start_period: 30s
    networks:
      - v2board-net

  mysql:
    image: mysql:8.0
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD is required}
      MYSQL_DATABASE: ${DB_DATABASE:-v2board}
      MYSQL_USER: ${DB_USERNAME:-v2board}
      MYSQL_PASSWORD: ${DB_PASSWORD:?DB_PASSWORD is required}
    command:
      - --default-authentication-plugin=mysql_native_password
      - --character-set-server=utf8mb4
      - --collation-server=utf8mb4_unicode_ci
    volumes:
      - mysql_data:/var/lib/mysql
    healthcheck:
      test: ["CMD-SHELL", "mysqladmin ping -h 127.0.0.1 -uroot -p$$MYSQL_ROOT_PASSWORD --silent"]
      interval: 10s
      timeout: 5s
      retries: 20
      start_period: 40s
    networks:
      - v2board-net

  redis:
    image: redis:7-alpine
    restart: unless-stopped
    environment:
      REDIS_PASSWORD: ${REDIS_PASSWORD:?REDIS_PASSWORD is required}
    command: ["sh", "-c", "exec redis-server --appendonly yes --requirepass \"$$REDIS_PASSWORD\""]
    volumes:
      - redis_data:/data
    healthcheck:
      test: ["CMD-SHELL", "redis-cli --no-auth-warning -a \"$$REDIS_PASSWORD\" ping | grep -q PONG"]
      interval: 10s
      timeout: 5s
      retries: 10
    networks:
      - v2board-net

networks:
  v2board-net:
    driver: bridge

volumes:
  mysql_data:
  redis_data:
```

- [ ] **Step 3: Verify required-variable validation fails**

Run:

```powershell
docker compose -f docker-compose.coolify.yml config
```

Expected: FAIL with `APP_URL is required`.

- [ ] **Step 4: Verify a complete production configuration expands**

Run:

```powershell
$env:APP_URL='https://board.example.com'
$env:APP_KEY='base64:MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY='
$env:MYSQL_ROOT_PASSWORD='test-root-password'
$env:DB_PASSWORD='test-db-password'
$env:REDIS_PASSWORD='test-redis-password'
$env:ADMIN_EMAIL='admin@example.com'
$env:ADMIN_PASSWORD='test-admin-password'
docker compose -f docker-compose.coolify.yml config --quiet
```

Expected: PASS with exit code 0.

- [ ] **Step 5: Confirm only Nginx is proxy-discoverable**

Run:

```powershell
docker compose -f docker-compose.coolify.yml config |
  Select-String -Pattern 'ports:|published:'
```

Expected: no matches. The expanded `nginx` service contains `expose: 80`; no service contains a published host port.

- [ ] **Step 6: Commit**

```powershell
git add -- docker-compose.coolify.yml
git commit -m "feat: add Coolify compose stack"
```

### Task 2: Make Runtime Configuration Stable

**Files:**
- Modify: `docker/entrypoint.sh:15-90`

**Interfaces:**
- Consumes: `APP_KEY` and `MAIL_*` variables passed by either Compose file
- Produces: a generated Laravel `.env` that preserves the provided application key and mail settings

- [ ] **Step 1: Record the current failing behavior**

Run:

```powershell
rg -n 'APP_KEY=|APP_KEY=\\$\\(php|MAIL_DRIVER|MAIL_HOST|MAIL_FROM_NAME' docker/entrypoint.sh
```

Expected: the script contains unconditional `APP_KEY=$(php ...)` assignment and contains no mail-variable defaults or mail `sed` updates.

- [ ] **Step 2: Add runtime defaults**

Add after the existing `APP_URL` default:

```bash
: "${APP_KEY:=}"
```

Add after the administrator defaults:

```bash
: "${MAIL_DRIVER:=smtp}"
: "${MAIL_HOST:=}"
: "${MAIL_PORT:=587}"
: "${MAIL_USERNAME:=}"
: "${MAIL_PASSWORD:=}"
: "${MAIL_ENCRYPTION:=tls}"
: "${MAIL_FROM_ADDRESS:=}"
: "${MAIL_FROM_NAME:=${APP_NAME}}"
```

- [ ] **Step 3: Preserve a supplied APP_KEY**

Replace the unconditional key assignment with:

```bash
if [ -z "$APP_KEY" ]; then
    APP_KEY=$(php -r "echo 'base64:'.base64_encode(random_bytes(32));")
fi
```

Keep the existing line that writes `APP_KEY` to `.env`.

- [ ] **Step 4: Propagate mail values into `.env`**

After the Redis update block, add:

```bash
    # Mail
    sed -i "s|^MAIL_DRIVER=.*|MAIL_DRIVER=${MAIL_DRIVER}|" .env
    sed -i "s|^MAIL_HOST=.*|MAIL_HOST=${MAIL_HOST}|" .env
    sed -i "s|^MAIL_PORT=.*|MAIL_PORT=${MAIL_PORT}|" .env
    sed -i "s|^MAIL_USERNAME=.*|MAIL_USERNAME=${MAIL_USERNAME}|" .env
    sed -i "s|^MAIL_PASSWORD=.*|MAIL_PASSWORD=${MAIL_PASSWORD}|" .env
    sed -i "s|^MAIL_ENCRYPTION=.*|MAIL_ENCRYPTION=${MAIL_ENCRYPTION}|" .env
    sed -i "s|^MAIL_FROM_ADDRESS=.*|MAIL_FROM_ADDRESS=${MAIL_FROM_ADDRESS}|" .env
    sed -i "s|^MAIL_FROM_NAME=.*|MAIL_FROM_NAME=${MAIL_FROM_NAME}|" .env
```

- [ ] **Step 5: Verify the intended script structure**

Run:

```powershell
rg -n 'if \\[ -z "\\$APP_KEY" \\]|MAIL_DRIVER:=smtp|MAIL_FROM_NAME:=|MAIL_FROM_NAME=\\$\\{MAIL_FROM_NAME\\}' docker/entrypoint.sh
```

Expected: all four patterns match.

- [ ] **Step 6: Check Bash syntax**

Run:

```powershell
docker run --rm -v "${PWD}:/work:ro" alpine:3.20 sh -c "apk add --no-cache bash >/dev/null && bash -n /work/docker/entrypoint.sh"
```

Expected: PASS with exit code 0 and no Bash syntax diagnostics.

- [ ] **Step 7: Revalidate both Compose configurations**

Run:

```powershell
docker compose -f docker-compose.yml --env-file .env.docker.example config --quiet
docker compose -f docker-compose.coolify.yml config --quiet
```

Expected: both commands exit 0 with the production test variables from Task 1 still set.

- [ ] **Step 8: Commit**

```powershell
git add -- docker/entrypoint.sh
git commit -m "fix: preserve container runtime settings"
```

### Task 3: Document Coolify Deployment

**Files:**
- Create: `docker/COOLIFY.md`
- Modify: `docker/README.md`

**Interfaces:**
- Consumes: the service names and required variables from `docker-compose.coolify.yml`
- Produces: operator instructions for first deployment, verification, upgrades, backups, and recovery

- [ ] **Step 1: Verify no dedicated guide exists**

Run:

```powershell
Test-Path docker/COOLIFY.md
```

Expected: `False`.

- [ ] **Step 2: Write the deployment guide**

Create `docker/COOLIFY.md` with these exact sections:

````markdown
# Deploy V2Board on Coolify

## Create the resource

Create a Docker Compose resource from this Git repository and select
`/docker-compose.coolify.yml` as the Compose file.

Assign the public domain only to the `nginx` service. Nginx listens on
container port 80; do not add a host port mapping.

## Required environment variables

Configure `APP_URL`, `APP_KEY`, `MYSQL_ROOT_PASSWORD`, `DB_PASSWORD`,
`REDIS_PASSWORD`, `ADMIN_EMAIL`, and `ADMIN_PASSWORD` in Coolify.

Generate `APP_KEY` once:

```sh
docker run --rm php:8.1-cli php -r \
  "echo 'base64:'.base64_encode(random_bytes(32)).PHP_EOL;"
```

Keep this value unchanged for all later deployments.

## First deployment

Deploy the resource, then inspect the `php` service logs. Confirm database
initialization, administrator creation, and `Initialization complete`.
Confirm all four services are healthy before opening `APP_URL`.

## Updates

Redeploy after pulling a new revision, then run:

```sh
php artisan v2board:update
```

inside the PHP service if the release contains database updates.

## Persistence and backups

MySQL data is stored in `mysql_data`; Redis AOF data is stored in
`redis_data`. Back up MySQL before upgrades. Never remove the stack with
volumes unless permanent data deletion is intended.

## Troubleshooting

- Check `php` logs for failed SQL imports or administrator creation.
- Check `php artisan horizon:status` inside the PHP service.
- Verify `APP_URL` exactly matches the HTTPS domain assigned to Nginx.
- Do not rotate `APP_KEY` on an existing deployment.
````

- [ ] **Step 3: Link the guide from the Docker README**

Add near the start of `docker/README.md`:

```markdown
> Coolify deployment: see [COOLIFY.md](COOLIFY.md).
```

- [ ] **Step 4: Verify documentation references match the Compose file**

Run:

```powershell
$required = 'APP_URL','APP_KEY','MYSQL_ROOT_PASSWORD','DB_PASSWORD','REDIS_PASSWORD','ADMIN_EMAIL','ADMIN_PASSWORD'
foreach ($name in $required) {
  if (-not (Select-String -Quiet -Path docker/COOLIFY.md -SimpleMatch $name)) {
    throw "Missing documentation for $name"
  }
}
```

Expected: PASS with no output.

- [ ] **Step 5: Commit**

```powershell
git add -- docker/COOLIFY.md docker/README.md
git commit -m "docs: add Coolify deployment guide"
```

### Task 4: Final Verification and Publication

**Files:**
- Review: `docker-compose.coolify.yml`
- Review: `docker/entrypoint.sh`
- Review: `docker/COOLIFY.md`
- Review: `docker/README.md`

**Interfaces:**
- Consumes: all prior task deliverables
- Produces: a validated branch, remote push, and draft pull request targeting `master`

- [ ] **Step 1: Review scope and whitespace**

Run:

```powershell
git status -sb
git diff master...HEAD --stat
git diff master...HEAD --check
```

Expected: only the design, plan, Coolify Compose, entrypoint, and Docker documentation are changed; `git diff --check` exits 0.

- [ ] **Step 2: Run full configuration validation**

Run:

```powershell
docker compose -f docker-compose.yml --env-file .env.docker.example config --quiet
docker compose -f docker-compose.coolify.yml config --quiet
docker run --rm -v "${PWD}:/work:ro" alpine:3.20 sh -c "apk add --no-cache bash >/dev/null && bash -n /work/docker/entrypoint.sh"
```

Expected: all commands exit 0.

- [ ] **Step 3: Build the Coolify images**

Run:

```powershell
docker compose -f docker-compose.coolify.yml build php nginx
```

Expected: both images build successfully.

- [ ] **Step 4: Inspect the final diff for secrets**

Run:

```powershell
git diff master...HEAD -- .gitattributes docker-compose.coolify.yml docker/entrypoint.sh docker/COOLIFY.md docker/README.md |
  Select-String -Pattern 'gho_|github_pat_|BEGIN.*PRIVATE KEY|MYSQL_ROOT_PASSWORD=[^$]|APP_KEY=base64:[A-Za-z0-9+/]{20,}'
```

Expected: no matches.

- [ ] **Step 5: Commit the implementation plan**

```powershell
git add -- docs/superpowers/plans/2026-07-27-coolify-deployment.md
git commit -m "docs: add Coolify implementation plan"
```

- [ ] **Step 6: Push the branch**

```powershell
git push -u origin agent/coolify-deployment
```

Expected: remote branch is created and tracking is configured.

- [ ] **Step 7: Open a draft pull request**

Create a draft PR targeting `master` with:

```text
Title: Add Coolify deployment support

Body:
- adds a dedicated Coolify Compose stack
- preserves a stable Laravel application key and mail settings
- adds authenticated dependency health checks
- documents deployment, upgrades, and persistence

Validation:
- docker compose config for local and Coolify stacks
- Bash syntax check for the container entrypoint
- Docker builds for PHP and Nginx images
```

Expected: a draft PR URL in `qdshow3011/v2board`.
