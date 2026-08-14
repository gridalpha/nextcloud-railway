# Nextcloud for Railway.
#
# The published `nextcloud:*-apache` image is very close to deployable as-is; this
# image only closes the gaps that are specific to running it on Railway. Each RUN
# block below states which one.
#
# The major version is pinned deliberately. Nextcloud's own entrypoint refuses to
# upgrade across more than one major at a time, so a floating `latest` would brick
# an instance whose owner redeploys after two majors have shipped. `34` still picks
# up every minor and patch release, including security fixes.
FROM nextcloud:34-apache

# 1. Background jobs.
#
# Upstream runs cron in a second container that bind-mounts the same /var/www/html
# volume as the web container. Railway volumes are strictly 1:1 — one volume, one
# service, never shared — so that split cannot be expressed here. Instead run both
# processes under supervisord in one container, which is exactly what upstream's own
# .examples/dockerfiles/cron/apache image does. This keeps Nextcloud in "Cron"
# background-job mode (the mode its documentation recommends) rather than falling
# back to AJAX or webcron.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends supervisor; \
    rm -rf /var/lib/apt/lists/*; \
    mkdir -p /var/log/supervisord /var/run/supervisord

# 2. Apache MPM.
#
# mod_php requires the prefork MPM. Recent php:*-apache builds leave mpm_event and
# mpm_worker enabled alongside it, and Apache aborts on
# "Configuration error: More than one MPM loaded." The container then restart-loops
# while the Railway deployment can still report SUCCESS and the public URL serves
# 502. Force prefork at build time so the running image is unambiguous.
RUN set -eux; \
    echo "== compiled-in modules:"; apache2 -l; \
    echo "== enabled MPM modules:"; ls -1 /etc/apache2/mods-enabled/ | grep -i mpm || true; \
    echo "== LoadModule lines mentioning mpm:"; grep -rn -i "loadmodule.*mpm" /etc/apache2/ || true; \
    if apache2 -l | grep -qE '(prefork|worker|event)\.c'; then \
        echo "an MPM is compiled in statically; removing every dynamically loaded MPM"; \
        rm -f /etc/apache2/mods-enabled/mpm_*.load /etc/apache2/mods-enabled/mpm_*.conf; \
    else \
        echo "no static MPM; leaving only mpm_prefork enabled for mod_php"; \
        rm -f /etc/apache2/mods-enabled/mpm_event.* /etc/apache2/mods-enabled/mpm_worker.*; \
        a2enmod mpm_prefork; \
    fi; \
    echo "== final MPM state:"; ls -1 /etc/apache2/mods-enabled/ | grep -i mpm || echo "(none dynamic)"; \
    apache2ctl -t

# 3. Client IP behind Railway's edge.
#
# The base image enables mod_remoteip with `RemoteIPHeader X-Real-IP` and trusts
# only RFC1918. Railway's proxy sits in 100.64.0.0/10 and sends X-Forwarded-For, so
# that config never fires — and pointing it at X-Forwarded-For would be worse, because
# mod_remoteip walks the header right-to-left and Railway's rightmost entry is its own
# public edge address, which rotates per request. Disable the conf and let Nextcloud
# resolve the client itself: its Request::getRemoteAddress() takes the leftmost entry
# that is not a trusted proxy, which is the real client. Configured by TRUSTED_PROXIES
# and FORWARDED_FOR_HEADERS at runtime.
RUN a2disconf remoteip

# 4. HSTS.
#
# Railway's edge redirects http to https but sets no Strict-Transport-Security of
# its own, and Nextcloud's setup checks flag its absence. Emit it from Apache, gated
# on the request having actually arrived over TLS so a plain-http health probe is
# unaffected.
RUN set -eux; \
    { \
        echo '<IfModule mod_headers.c>'; \
        echo '  Header always set Strict-Transport-Security "max-age=15552000; includeSubDomains" "expr=%{HTTP:X-Forwarded-Proto} == '"'"'https'"'"'"'; \
        echo '</IfModule>'; \
    } > /etc/apache2/conf-available/railway-hsts.conf; \
    a2enconf railway-hsts; \
    apache2ctl -t

COPY supervisord.conf /supervisord.conf
COPY railway-entrypoint.sh /railway-entrypoint.sh
COPY bootstrap-db.php /bootstrap-db.php
COPY hooks/before-starting/ /docker-entrypoint-hooks.d/before-starting/
RUN set -eux; \
    chmod +x /railway-entrypoint.sh /docker-entrypoint-hooks.d/before-starting/*.sh; \
    php -l /bootstrap-db.php; \
    sh -n /railway-entrypoint.sh; \
    sh -n /docker-entrypoint-hooks.d/before-starting/10-railway.sh

# The image's own entrypoint only runs its install/upgrade block when its first
# argument looks like `apache*` or `php-fpm`. Ours is supervisord, so ask for the
# block explicitly.
ENV NEXTCLOUD_UPDATE=1

ENTRYPOINT ["/railway-entrypoint.sh"]
CMD ["/usr/bin/supervisord", "-c", "/supervisord.conf"]
