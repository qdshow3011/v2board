FROM nginx:1.25-alpine

# Bake nginx config into the image (avoids bind-mount issues on Coolify)
COPY v2board.conf /etc/nginx/conf.d/default.conf

EXPOSE 80
