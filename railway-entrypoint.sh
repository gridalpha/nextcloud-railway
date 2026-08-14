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

# Apache's MPM state is normalised at build time, but report and re-assert it here
# too: the build's own `apache2ctl -t` passes while the running container can still
# abort with "More than one MPM loaded", so the running configuration is what counts.
echo "railway-entrypoint: dynamic MPM modules: $(ls -1 /etc/apache2/mods-enabled/ 2>/dev/null | grep -i mpm | tr '\n' ' ')"
echo "railway-entrypoint: compiled-in MPM: $(apache2 -l | grep -E '(prefork|worker|event)\.c' | tr -d ' ' | tr '\n' ' ')"
grep -rn -i "loadmodule.*mpm" /etc/apache2/apache2.conf /etc/apache2/conf-enabled/ /etc/apache2/mods-enabled/ /etc/apache2/sites-enabled/ 2>/dev/null || true
apache2ctl -t 2>&1 | sed 's/^/railway-entrypoint: apache2ctl -t: /' || true

php /bootstrap-db.php

exec /entrypoint.sh "$@"
