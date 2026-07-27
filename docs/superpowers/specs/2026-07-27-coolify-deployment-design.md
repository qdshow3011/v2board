# Coolify Deployment Design

## Goal

Make V2Board reproducibly deployable from this repository as a Coolify
Docker Compose application without changing the behavior of the existing
local Compose deployment.

## Approach

Add a dedicated `docker-compose.coolify.yml` and keep `docker-compose.yml`
for local, host-port-based use. Coolify will route the configured public
domain to the `nginx` service on container port 80. PHP-FPM, MySQL, and
Redis remain private to the Compose network.

## Services

### Nginx

- Build from `docker/nginx/Dockerfile`.
- Expose container port 80 without publishing a host port.
- Route PHP requests to `php:9000`.
- Report health through the existing `/health` endpoint.
- Start only after the PHP service is healthy.

### PHP

- Build from the root `Dockerfile`.
- Run PHP-FPM, Laravel Horizon, and cron under Supervisor.
- Receive all Laravel, database, Redis, administrator, and mail settings
  from Coolify environment variables.
- Require stable production secrets through Compose required-variable
  expansion.

### MySQL

- Use the pinned `mysql:8.0` image.
- Store data in a named volume.
- Use a password-aware health check.
- Remain accessible only on the internal Compose network.

### Redis

- Use `redis:7-alpine`.
- Require authentication in production.
- Store append-only data in a named volume.
- Use an authenticated health check.
- Remain accessible only on the internal Compose network.

## Environment and Secret Handling

Coolify will discover variables referenced by the Compose file. Production
secrets and deployment-specific values use `${VARIABLE:?}` so deployment
fails before container creation when a required value is missing.

Required values:

- `APP_URL`
- `APP_KEY`
- `MYSQL_ROOT_PASSWORD`
- `DB_PASSWORD`
- `REDIS_PASSWORD`
- `ADMIN_EMAIL`
- `ADMIN_PASSWORD`

`APP_KEY` must remain stable across rebuilds. The entrypoint will use the
provided value and generate a key only as a local-development fallback.
Mail variables will be propagated into the generated Laravel `.env`.

## Initialization and Data Flow

On first deployment:

1. MySQL and Redis become healthy.
2. PHP creates `.env` from runtime configuration and caches Laravel config.
3. Supervisor starts PHP-FPM, Horizon, and cron.
4. The entrypoint imports `database/install.sql` when `v2_user` is absent.
5. The entrypoint creates the configured administrator when needed.
6. Nginx becomes healthy and Coolify routes the public domain to it.

Later deployments reuse the MySQL and Redis named volumes. A fixed
`APP_KEY` prevents encrypted application state from changing between image
rebuilds.

## Error Handling

- Missing required production values stop Compose interpolation.
- Dependency health checks gate PHP startup.
- PHP-FPM health gates Nginx startup.
- Redis health checks authenticate with the configured password.
- Existing entrypoint warnings remain visible in PHP container logs.

## Documentation

Add a Coolify deployment guide covering:

- repository and Compose file selection;
- domain assignment to the `nginx` service;
- required environment variables;
- first-start log verification;
- upgrades, backups, and the risk of deleting named volumes.

## Validation

- Confirm the original worktree is clean before modifications.
- Verify the Coolify Compose file with `docker compose config`.
- Verify required-variable failures with an intentionally empty environment.
- Check `docker/entrypoint.sh` syntax using Bash in a container or available
  local shell.
- Run relevant project tests when dependencies are available.
- Review the final diff for unrelated changes and exposed secrets.

## Out of Scope

- Deploying to a live Coolify server.
- Changing V2Board application behavior.
- Migrating MySQL or Redis to external managed services.
- Adding a container registry or CI/CD workflow.
