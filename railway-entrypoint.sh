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

php /bootstrap-db.php

exec /entrypoint.sh "$@"
