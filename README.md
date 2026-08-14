# nextcloud-railway

Nextcloud, packaged to run on Railway as a single service alongside managed
PostgreSQL, managed Redis and a Railway object-storage bucket.

The image is the official `nextcloud:34-apache` with four Railway-specific changes,
each explained inline in the [Dockerfile](Dockerfile):

1. **Apache and Nextcloud's cron run together under supervisord.** Upstream splits
   them into two containers sharing one bind mount; Railway volumes are strictly
   1:1, so the split cannot be expressed and the two processes share a container
   instead — the same shape as upstream's own
   `.examples/dockerfiles/cron/apache` image. This keeps background jobs in
   Nextcloud's recommended **Cron** mode rather than the AJAX fallback.
2. **The prefork MPM is forced at build time.** `mod_php` needs it, and recent
   `php:*-apache` builds leave `mpm_event`/`mpm_worker` enabled too, which aborts
   Apache with `More than one MPM loaded`.
3. **`mod_remoteip` is disabled** so Nextcloud resolves the client IP itself, from
   the leftmost non-proxy entry of `X-Forwarded-For`. Pointing `mod_remoteip` at
   that header would pick Railway's own rotating edge address instead.
4. **The app gets its own PostgreSQL role and database** at boot
   ([bootstrap-db.php](bootstrap-db.php)), rather than being handed Railway's
   `postgres` superuser.

## Configuration

Everything is standard `nextcloud/docker` configuration except one variable:

| Variable | Purpose |
|---|---|
| `NEXTCLOUD_DB_BOOTSTRAP_URL` | Superuser URL (`${{Postgres.DATABASE_URL}}`) used once per boot to create/refresh the scoped role and database named by `POSTGRES_USER` / `POSTGRES_DB`. Leave unset to skip and use `POSTGRES_*` exactly as supplied. |
| `NEXTCLOUD_DEFAULT_PHONE_REGION` | ISO country code for phone-number parsing. Defaults to `US`. |
| `NEXTCLOUD_MAINTENANCE_WINDOW_START` | UTC hour at which heavy background jobs may run. Defaults to `1`. |

Upstream's variables — `POSTGRES_*`, `REDIS_HOST*`, `OBJECTSTORE_S3_*`,
`NEXTCLOUD_ADMIN_*`, `NEXTCLOUD_TRUSTED_DOMAINS`, `OVERWRITE*`, `TRUSTED_PROXIES`,
`PHP_*` — behave exactly as documented at
<https://github.com/nextcloud/docker#configuration>.

Apache listens on port 80.
