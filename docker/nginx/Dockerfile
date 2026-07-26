FROM nginx:1.25-alpine

# Copy app code for serving static files (CSS, JS, images)
# Build context is project root, .dockerignore excludes vendor/.git etc.
COPY . /var/www/html/

# Bake nginx config into the image (avoids bind-mount issues on Coolify)
COPY docker/nginx/v2board.conf /etc/nginx/conf.d/default.conf

# Fix permissions for nginx to read static files
RUN chown -R nginx:nginx /var/www/html/public 2>/dev/null || true

EXPOSE 80
