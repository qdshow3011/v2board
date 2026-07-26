#!/bin/bash
set -e

# ============================================================
#  V2Board Docker Entrypoint
#  Non-interactive initialization: env, DB import, admin user
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
: "${ADMIN_EMAIL:=admin@v2board.com}"
: "${ADMIN_PASSWORD:=}"

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
    echo "[entrypoint] ERROR: $name at $host:$port not reachable after 120s."
    return 1
}

# ---- Wait for dependencies ----
wait_for "$DB_HOST" "$DB_PORT" "MySQL"
wait_for "$REDIS_HOST" "$REDIS_PORT" "Redis"

# ---- Composer install (if vendor dir is missing) ----
if [ ! -d "vendor" ]; then
    echo "[entrypoint] Installing Composer dependencies..."
    composer install --no-dev --optimize-autoloader --no-interaction
fi

# ---- Generate .env from template if missing ----
if [ ! -f ".env" ]; then
    echo "[entrypoint] Creating .env from environment variables..."
    cp .env.example .env

    # Generate APP_KEY
    APP_KEY=$(php -r "echo 'base64:'.base64_encode(random_bytes(32));")
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

    # Cache & Queue
    sed -i "s|^CACHE_DRIVER=.*|CACHE_DRIVER=redis|" .env
    sed -i "s|^SESSION_DRIVER=.*|SESSION_DRIVER=redis|" .env

    echo "[entrypoint] .env created."
else
    echo "[entrypoint] .env already exists, skipping generation."
fi

# ---- Laravel config cache ----
php artisan config:clear 2>/dev/null || true
php artisan config:cache 2>/dev/null || true

# ---- Import database if not initialized ----
check_table=$(mysql -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USERNAME" -p"$DB_PASSWORD" \
    "$DB_DATABASE" -N -e "SHOW TABLES LIKE 'v2_user';" 2>/dev/null || true)

if [ -z "$check_table" ]; then
    echo "[entrypoint] Database not initialized. Importing install.sql..."
    mysql -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USERNAME" -p"$DB_PASSWORD" \
        "$DB_DATABASE" < database/install.sql 2>/dev/null
    echo "[entrypoint] Database schema imported."
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
" 2>/dev/null

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
chown -R www-data:www-data storage bootstrap/cache
chmod -R 777 storage bootstrap/cache

# ---- Create log directory for horizon ----
mkdir -p storage/logs/queue
chown -R www-data:www-data storage/logs/queue

echo "[entrypoint] Initialization complete. Starting services..."

# ---- Hand off to CMD (supervisord) ----
exec "$@"
