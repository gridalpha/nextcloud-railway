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
# Clearing the marker makes the next boot re-run initialisation. Safe by
# construction: config.php is the file a real installation writes, so this cannot
# fire on an instance that has any data to lose.
if [ -f /var/www/html/version.php ] && [ ! -f /var/www/html/config/config.php ]; then
    echo "railway-entrypoint: application files present but never installed (no config.php) - clearing version.php so initialisation runs again"
    rm -f /var/www/html/version.php
fi

php /bootstrap-db.php

exec /entrypoint.sh "$@"
