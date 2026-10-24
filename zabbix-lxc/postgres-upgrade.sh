#!/bin/bash
# ==============================================================================
# Script: Automated PostgreSQL Major Version In-Place Upgrade
# Target OS: Arch Linux (Zabbix Container)
# Purpose: Upgrades PostgreSQL data directories between major versions using
#          pg_upgrade and binaries extracted from the previous cached package.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# 1. Stop Services to Prevent Concurrency & Lock Contention
# ------------------------------------------------------------------------------
# Stop Zabbix Server first so it releases active DB connections and locks
systemctl stop zabbix-server-pgsql || true

# Stop and disable PostgreSQL before touching the data directory
systemctl disable postgresql --now || true

# ------------------------------------------------------------------------------
# 2. Locate Previous PostgreSQL Package in Pacman Cache
# ------------------------------------------------------------------------------
# Enable nullglob to avoid literal glob strings if no matches exist
shopt -s nullglob
raw_pkgs=(/var/cache/pacman/pkg/postgresql-[0-9]*.pkg.tar.*)
shopt -u nullglob

if [ ${#raw_pkgs[@]} -lt 2 ]; then
    echo "Error: Need at least two PostgreSQL packages in /var/cache/pacman/pkg/ to upgrade." >&2
    exit 1
fi

# Sort packages by natural version order and select the second-to-last archive
mapfile -t sorted_pkgs < <(printf '%s\n' "${raw_pkgs[@]}" | sort -V)
lastversion="${sorted_pkgs[-2]}"

echo "Using previous package: $lastversion"

# ------------------------------------------------------------------------------
# 3. Stage Working Directories
# ------------------------------------------------------------------------------
# Rename existing cluster data to 'olddata' and prepare target and temp directories
mv /var/lib/postgres/data /var/lib/postgres/olddata
mkdir -p /var/lib/postgres/data /var/lib/postgres/tmp

# Stage the old package tarball into temporary working space
cp "$lastversion" /var/lib/postgres/tmp/
chown -R postgres:postgres /var/lib/postgres/data /var/lib/postgres/tmp

# ------------------------------------------------------------------------------
# 4. Extract Binaries, Initialize Cluster & Execute pg_upgrade
# ------------------------------------------------------------------------------
(
    cd /var/lib/postgres/tmp || exit 1

    # Extract the previous package to supply old binaries and shared libraries
    tar -xf "$(basename "$lastversion")"

    # Initialize a clean, empty target database cluster with UTF-8 locale
    su postgres -P -c 'initdb --locale=en_GB.UTF-8 -E UTF8 -D /var/lib/postgres/data'

    # Preserve custom postgresql.conf and pg_hba.conf from the old cluster
    cp /var/lib/postgres/olddata/postgresql.conf /var/lib/postgres/data/postgresql.conf
    cp /var/lib/postgres/olddata/pg_hba.conf /var/lib/postgres/data/pg_hba.conf
    chown postgres:postgres /var/lib/postgres/data/*.conf

    # Run pg_upgrade with LD_LIBRARY_PATH pointed to extracted old shared libraries
    su postgres -P -c 'LD_LIBRARY_PATH=/var/lib/postgres/tmp/usr/lib pg_upgrade \
        -b /var/lib/postgres/tmp/usr/bin \
        -B /usr/bin \
        -d /var/lib/postgres/olddata \
        -D /var/lib/postgres/data'

    # Start new PostgreSQL service
    systemctl enable postgresql --now

    # Rebuild database indexes across system and application databases
    su postgres -P -c 'reindexdb -d template1 && reindexdb -d postgres && reindexdb -d zabbix'

    # Refresh collation versions to match current glibc definitions
    su postgres -P -c 'psql -U postgres -c "\
        ALTER DATABASE template1 REFRESH COLLATION VERSION; \
        ALTER DATABASE postgres REFRESH COLLATION VERSION; \
        ALTER DATABASE zabbix REFRESH COLLATION VERSION;"'

    # Re-generate query planner optimizer statistics in progressive stages
    su postgres -P -c '/usr/bin/vacuumdb --all --analyze-in-stages'

    # Restart Zabbix Server against the updated database
    systemctl start zabbix-server-pgsql
)

# ------------------------------------------------------------------------------
# 5. Clean Up Working Files
# ------------------------------------------------------------------------------
# Remove temp extraction directory while leaving olddata as an intact safety net
rm -rf /var/lib/postgres/tmp
echo "Upgrade complete. Verify Zabbix functionality, then manually remove /var/lib/postgres/olddata."