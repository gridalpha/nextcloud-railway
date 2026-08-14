#!/bin/sh
# PID 1. Repairs a half-initialised volume, provisions the app's own database role,
# then hands off to the stock Nextcloud entrypoint, which installs or upgrades and
# finally execs supervisord.
set -eu

# The image decides "Nextcloud is already installed here" from version.php alone,
# which it writes during the same rsync that unpacks the application. A container
# that unpacked the app but never completed installation — a first boot before the
# database variables existed, an interrupted deploy — therefore leaves a volume that
# looks installed and is not, and every later boot skips installation for good. The
# instance serves a 500 and no amount of correct configuration fixes it.
#
# Clearing the marker makes the next boot re-run initialisation. Test the config's
# own `installed` flag rather than merely whether config.php exists: a single HTTP
# request to an uninstalled instance is enough for Nextcloud to persist an
# instanceid, passwordsalt and secret into config.php, so the file's presence says
# nothing about whether an installation ever completed. The flag does, and it is
# only ever true once there is data worth protecting.
if [ -f /var/www/html/version.php ] \
    && ! grep -qE "'installed'[[:space:]]*=>[[:space:]]*true" /var/www/html/config/config.php 2>/dev/null; then
    echo "railway-entrypoint: application files present but installation never completed - clearing version.php so initialisation runs again"
    rm -f /var/www/html/version.php
fi

# Apache's MPM state has to be fixed here rather than in the Dockerfile.
#
# mod_php only works under the prefork MPM, and Apache refuses to start at all with
# "AH00534: Configuration error: More than one MPM loaded." The Dockerfile disables
# mpm_event and mpm_worker and its `apache2ctl -t` passes — and the container that
# Railway then runs still has mpm_event.load back in mods-enabled alongside
# mpm_prefork.load, and still aborts. The build's view of /etc/apache2 is not the
# view the running container gets, so the running container is where this belongs.
#
# Symptom if this is ever removed: Apache exits 1 in a tight loop under supervisord,
# the deployment reports SUCCESS because cron keeps the container alive, and every
# request to the public domain returns 502.
if [ "$(ls -1 /etc/apache2/mods-enabled/ 2>/dev/null | grep -c '^mpm_.*\.load$')" -gt 1 ]; then
    echo "railway-entrypoint: more than one MPM enabled ($(ls -1 /etc/apache2/mods-enabled/ | grep '^mpm_.*\.load$' | tr '\n' ' ')) - keeping only prefork for mod_php"
    rm -f /etc/apache2/mods-enabled/mpm_event.* /etc/apache2/mods-enabled/mpm_worker.*
    a2enmod mpm_prefork >/dev/null
fi
apache2ctl -t 2>&1 | sed 's/^/railway-entrypoint: apache2ctl -t: /'

php /bootstrap-db.php

exec /entrypoint.sh "$@"
