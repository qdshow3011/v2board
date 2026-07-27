FROM php:8.1-fpm-alpine

LABEL maintainer="v2board-docker"
LABEL description="V2Board - PHP-FPM with Supervisor for queue & scheduler"

# ---------- System dependencies ----------
RUN apk add --no-cache \
    supervisor \
    mysql-client \
    curl \
    wget \
    git \
    bash \
    tzdata \
    netcat-openbsd \
    libzip-dev \
    libpng-dev \
    libjpeg-turbo-dev \
    freetype-dev \
    libxml2-dev \
    oniguruma-dev \
    icu-dev \
    autoconf \
    g++ \
    make \
    linux-headers \
    && cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime \
    && echo "Asia/Shanghai" > /etc/timezone

# ---------- PHP extensions ----------
RUN docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j$(nproc) \
        pdo_mysql \
        mysqli \
        zip \
        gd \
        bcmath \
        opcache \
        pcntl \
        intl \
        soap \
        mbstring \
        xml \
        fileinfo

# Redis extension
RUN pecl install redis && docker-php-ext-enable redis

# Memcached (optional, for future use)
# RUN pecl install memcached && docker-php-ext-enable memcached

# ---------- Composer ----------
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

# ---------- Application ----------
WORKDIR /var/www/html

COPY . /var/www/html

# Configure composer: use Alibaba mirror for China connectivity + longer timeout
ENV COMPOSER_ALLOW_XDEBUG=1
ENV COMPOSER_PROCESS_TIMEOUT=600
ENV COMPOSER_NO_INTERACTION=1
RUN composer config -g repo.packagist composer https://mirrors.aliyun.com/composer/

# Install Composer dependencies during BUILD (not runtime)
# --no-scripts: skip post-autoload-dump (artisan package:discover) which fails
#   without .env; these scripts run in entrypoint.sh instead
# This ensures vendor/ exists when PHP-FPM starts, preventing 502 errors
RUN composer install --no-dev --no-scripts --optimize-autoloader

# Copy Docker config files
COPY docker/supervisor/supervisord.conf /etc/supervisord.conf
COPY docker/supervisor/conf.d/ /etc/supervisor.d/
COPY docker/php-fpm/zz-docker.conf /usr/local/etc/php-fpm.d/zz-docker.conf
COPY docker/entrypoint.sh /entrypoint.sh
COPY docker/cron/v2board /etc/crontabs/www-data

RUN chmod +x /entrypoint.sh \
    && mkdir -p storage/framework/cache/data \
              storage/framework/sessions \
              storage/framework/views \
              storage/logs \
              bootstrap/cache \
    && chown -R www-data:www-data /var/www/html \
    && chmod -R 755 /var/www/html \
    && chmod -R 777 storage bootstrap/cache

EXPOSE 9000

ENTRYPOINT ["/entrypoint.sh"]
CMD ["supervisord", "-c", "/etc/supervisord.conf"]
