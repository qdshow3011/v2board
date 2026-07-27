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
