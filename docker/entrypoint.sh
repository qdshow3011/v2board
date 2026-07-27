#!/bin/bash
# Do NOT use set -e — non-critical failures should not kill the container
set -uo pipefail

# ============================================================
#  V2Board Docker Entrypoint
#  Starts supervisord FIRST (PHP-FPM on :9000 immediately),
#  then runs init steps in foreground.
#  This ensures healthcheck passes while init is running.
# ============================================================

WORK_DIR="/var/www/html"
cd "$WORK_DIR"

# ---- Default environment values ----
: "${DB_HOST:=mysql}"
: "${DB_PORT:=3306}"
: "${DB_DATABASE:=v2board}"
: "${DB_USERNAME:=v2board}"
: "${DB_PASSWORD:=v2board_secret}"
: "${REDIS_HOST:=redis}"
: "${REDIS_PORT:=6379}"
: "${REDIS_PASSWORD:=}"
: "${APP_NAME:=V2Board}"
: "${APP_ENV:=production}"
: "${APP_DEBUG:=false}"
: "${APP_URL:=http://localhost}"
: "${APP_KEY:=}"
: "${ADMIN_EMAIL:=admin@v2board.com}"
: "${ADMIN_PASSWORD:=}"
: "${MAIL_DRIVER:=smtp}"
: "${MAIL_HOST:=}"
: "${MAIL_PORT:=587}"
: "${MAIL_USERNAME:=}"
: "${MAIL_PASSWORD:=}"
: "${MAIL_ENCRYPTION:=tls}"
: "${MAIL_FROM_ADDRESS:=}"
: "${MAIL_FROM_NAME:=${APP_NAME}}"

# ============================================================
# PHASE 1: Create .env FIRST (before anything else)
# so PHP-FPM can serve requests immediately after starting
# ============================================================
if [ ! -f ".env" ]; then
    echo "[entrypoint] Creating .env from environment variables..."
    if [ -f ".env.example" ]; then
        cp .env.example .env
    else
        # Minimal .env if no template exists
        cat > .env <<EOFNV
APP_NAME=${APP_NAME}
APP_ENV=${APP_ENV}
APP_KEY=
APP_DEBUG=${APP_DEBUG}
APP_URL=${APP_URL}
DB_CONNECTION=mysql
DB_HOST=${DB_HOST}
DB_PORT=${DB_PORT}
DB_DATABASE=${DB_DATABASE}
DB_USERNAME=${DB_USERNAME}
DB_PASSWORD=${DB_PASSWORD}
REDIS_HOST=${REDIS_HOST}
REDIS_PORT=${REDIS_PORT}
CACHE_DRIVER=redis
SESSION_DRIVER=redis
QUEUE_CONNECTION=redis
EOFNV
    fi

    # Generate APP_KEY only when one was not supplied or is invalid format.
    # Laravel requires base64: prefix with 32 raw bytes (44 chars after base64:).
    if [ -z "$APP_KEY" ] || ! echo "$APP_KEY" | grep -q '^base64:'; then
        APP_KEY=$(php -r "echo 'base64:'.base64_encode(random_bytes(32));")
    fi
    sed -i "s|^APP_NAME=.*|APP_NAME=${APP_NAME}|" .env
    sed -i "s|^APP_ENV=.*|APP_ENV=${APP_ENV}|" .env
    sed -i "s|^APP_KEY=.*|APP_KEY=${APP_KEY}|" .env
    sed -i "s|^APP_DEBUG=.*|APP_DEBUG=${APP_DEBUG}|" .env
    sed -i "s|^APP_URL=.*|APP_URL=${APP_URL}|" .env

    # Database
    sed -i "s|^DB_HOST=.*|DB_HOST=${DB_HOST}|" .env
    sed -i "s|^DB_PORT=.*|DB_PORT=${DB_PORT}|" .env
    sed -i "s|^DB_DATABASE=.*|DB_DATABASE=${DB_DATABASE}|" .env
    sed -i "s|^DB_USERNAME=.*|DB_USERNAME=${DB_USERNAME}|" .env
    sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=${DB_PASSWORD}|" .env

    # Redis
    sed -i "s|^REDIS_HOST=.*|REDIS_HOST=${REDIS_HOST}|" .env
    sed -i "s|^REDIS_PORT=.*|REDIS_PORT=${REDIS_PORT}|" .env
    if [ -n "$REDIS_PASSWORD" ] && [ "$REDIS_PASSWORD" != "null" ]; then
        sed -i "s|^REDIS_PASSWORD=.*|REDIS_PASSWORD=${REDIS_PASSWORD}|" .env
    fi

    # Mail
    sed -i "s|^MAIL_DRIVER=.*|MAIL_DRIVER=${MAIL_DRIVER}|" .env
    sed -i "s|^MAIL_HOST=.*|MAIL_HOST=${MAIL_HOST}|" .env
    sed -i "s|^MAIL_PORT=.*|MAIL_PORT=${MAIL_PORT}|" .env
    sed -i "s|^MAIL_USERNAME=.*|MAIL_USERNAME=${MAIL_USERNAME}|" .env
    sed -i "s|^MAIL_PASSWORD=.*|MAIL_PASSWORD=${MAIL_PASSWORD}|" .env
    sed -i "s|^MAIL_ENCRYPTION=.*|MAIL_ENCRYPTION=${MAIL_ENCRYPTION}|" .env
    sed -i "s|^MAIL_FROM_ADDRESS=.*|MAIL_FROM_ADDRESS=${MAIL_FROM_ADDRESS}|" .env
    sed -i "s|^MAIL_FROM_NAME=.*|MAIL_FROM_NAME=${MAIL_FROM_NAME}|" .env

    # Cache & Queue
    sed -i "s|^CACHE_DRIVER=.*|CACHE_DRIVER=redis|" .env
    sed -i "s|^SESSION_DRIVER=.*|SESSION_DRIVER=redis|" .env

    echo "[entrypoint] .env created."
else
    echo "[entrypoint] .env already exists, skipping generation."
fi

# ---- Validate and fix APP_KEY (even if .env already exists) ----
CURRENT_KEY=$(grep "^APP_KEY=" .env | cut -d'=' -f2-)
if [ -z "$CURRENT_KEY" ] || ! echo "$CURRENT_KEY" | grep -q '^base64:'; then
    echo "[entrypoint] APP_KEY is missing or invalid format (must start with base64:). Generating new key..."
    NEW_KEY=$(php -r "echo 'base64:'.base64_encode(random_bytes(32));")
    sed -i "s|^APP_KEY=.*|APP_KEY=${NEW_KEY}|" .env
    echo "[entrypoint] APP_KEY regenerated."
else
    echo "[entrypoint] APP_KEY format OK."
fi

# ---- Laravel config cache (run before PHP-FPM starts) ----
php artisan config:clear 2>/dev/null || true
php artisan config:cache 2>/dev/null || echo "[entrypoint] WARNING: config:cache failed, continuing..."

# ---- Run package discovery (skipped during build via --no-scripts) ----
php artisan package:discover 2>/dev/null || echo "[entrypoint] WARNING: package:discover failed, continuing..."

# ============================================================
# PHASE 2: Start supervisord immediately (PHP-FPM on :9000)
# Now .env and vendor/ are ready, so PHP can serve requests
# ============================================================
echo "[entrypoint] Starting supervisord (PHP-FPM, Horizon, Cron)..."
supervisord -c /etc/supervisord.conf &
SUPERVISOR_PID=$!

# Give PHP-FPM a moment to bind to port 9000
sleep 3
echo "[entrypoint] PHP-FPM should be listening on :9000 now."

# ============================================================
# PHASE 3: Run database initialization (in background-safe order)
# ============================================================

# ---- Helper: wait for a TCP service ----
wait_for() {
    local host="$1" port="$2" name="$3"
    echo "[entrypoint] Waiting for $name at $host:$port ..."
    for i in $(seq 1 60); do
        if nc -z "$host" "$port" 2>/dev/null; then
            echo "[entrypoint] $name is up."
            return 0
        fi
        sleep 2
    done
    echo "[entrypoint] WARNING: $name at $host:$port not reachable after 120s, continuing anyway..."
    return 1
}

# ---- Wait for dependencies ----
wait_for "$DB_HOST" "$DB_PORT" "MySQL"
wait_for "$REDIS_HOST" "$REDIS_PORT" "Redis"

# ---- Composer install (fallback: if vendor/ missing from volume) ----
if [ ! -d "vendor" ]; then
    echo "[entrypoint] vendor/ missing, installing Composer dependencies..."
    composer install --no-dev --optimize-autoloader --no-interaction || {
        echo "[entrypoint] WARNING: composer install failed, continuing..."
    }
    # Restart horizon so it picks up the newly installed autoload
    supervisorctl restart horizon 2>/dev/null || true
else
    echo "[entrypoint] vendor/ exists, skipping composer install."
fi

# ---- Import database if not initialized ----
check_table=$(mysql --skip-ssl -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USERNAME" -p"$DB_PASSWORD" \
    "$DB_DATABASE" -N -e "SHOW TABLES LIKE 'v2_user';" 2>/dev/null || true)

if [ -z "$check_table" ]; then
    echo "[entrypoint] Database not initialized. Importing install.sql..."
    mysql --skip-ssl -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USERNAME" -p"$DB_PASSWORD" \
        "$DB_DATABASE" < database/install.sql 2>/dev/null || echo "[entrypoint] WARNING: SQL import failed, continuing..."
    echo "[entrypoint] Database schema import attempted."
else
    echo "[entrypoint] Database already initialized, skipping import."
fi

# ---- Create admin user if not exists ----
ADMIN_EXISTS=$(php -r "
require 'vendor/autoload.php';
\$app = require 'bootstrap/app.php';
\$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
echo \App\Models\User::where('email', '${ADMIN_EMAIL}')->exists() ? '1' : '0';
" 2>/dev/null || echo "0")

if [ "$ADMIN_EXISTS" = "0" ]; then
    echo "[entrypoint] Creating admin user: ${ADMIN_EMAIL}"

    # Generate a random password if none provided
    if [ -z "$ADMIN_PASSWORD" ]; then
        ADMIN_PASSWORD=$(php -r "echo bin2hex(random_bytes(6));")
    fi

    php -r "
require 'vendor/autoload.php';
\$app = require 'bootstrap/app.php';
\$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
\$user = new \App\Models\User();
\$user->email = '${ADMIN_EMAIL}';
\$user->password = password_hash('${ADMIN_PASSWORD}', PASSWORD_DEFAULT);
\$user->uuid = \App\Utils\Helper::guid(true);
\$user->token = \App\Utils\Helper::guid();
\$user->is_admin = 1;
\$user->save();
echo 'OK';
" 2>/dev/null || echo "[entrypoint] WARNING: admin user creation failed, continuing..."

    echo ""
    echo "================================================"
    echo "  Admin Email:    ${ADMIN_EMAIL}"
    echo "  Admin Password: ${ADMIN_PASSWORD}"
    echo "================================================"
    echo ""
else
    echo "[entrypoint] Admin user already exists: ${ADMIN_EMAIL}"
fi

# ---- Fix permissions ----
chown -R www-data:www-data storage bootstrap/cache 2>/dev/null || true
chmod -R 777 storage bootstrap/cache 2>/dev/null || true

# ---- Create log directory for horizon ----
mkdir -p storage/logs/queue
chown -R www-data:www-data storage/logs/queue

echo "[entrypoint] Initialization complete. Services running via supervisord."

# ============================================================
# PHASE 4: Wait for supervisord to keep container alive
# ============================================================
wait $SUPERVISOR_PID
