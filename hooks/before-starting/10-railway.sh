#!/bin/sh
# Runs as www-data on every boot, after the image has finished installing or
# upgrading Nextcloud and before Apache starts. Everything here is idempotent.
#
# Deliberately not `set -e`: none of these settings is required for Nextcloud to
# serve, so a failure is reported and the boot continues.

occ() {
    php /var/www/html/occ "$@" || echo "10-railway: '$*' failed (continuing)"
}

# NEXTCLOUD_TRUSTED_DOMAINS is only honoured during the initial install, but Railway
# mints a different public domain for every project and environment a template is
# deployed into. Re-assert it on each boot so the instance is reachable at whatever
# domain it currently has, instead of answering "access through untrusted domain".
if [ -n "${RAILWAY_PUBLIC_DOMAIN:-}" ]; then
    occ config:system:set trusted_domains 1 --value="$RAILWAY_PUBLIC_DOMAIN"
fi

# Run background jobs from real cron (supervisord runs busybox crond alongside
# Apache) rather than the AJAX fallback, which only fires while someone has a page
# open and which Nextcloud's admin overview flags as unsuitable for production.
occ background:cron

# Two settings whose absence Nextcloud reports as configuration warnings.
occ config:system:set default_phone_region --value="${NEXTCLOUD_DEFAULT_PHONE_REGION:-US}"
occ config:system:set maintenance_window_start --type=integer --value="${NEXTCLOUD_MAINTENANCE_WINDOW_START:-1}"

# Schema housekeeping upstream expects an administrator to run after an upgrade.
# No-ops once the schema is current.
occ db:add-missing-columns
occ db:add-missing-indices
occ db:add-missing-primary-keys
