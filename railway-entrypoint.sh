#!/bin/sh
# PID 1. Provisions the app's own database role, then hands off to the stock
# Nextcloud entrypoint, which installs/upgrades and finally execs supervisord.
set -eu

php /bootstrap-db.php

exec /entrypoint.sh "$@"
