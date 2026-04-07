#!/bin/bash

# Executed as
# docker compose run --rm backup

set -euo pipefail

echo "==== Backup Check Started ===="

#################################################
# Verify script runs as PID 1
#################################################
if [ "$$" -ne 1 ]; then
    echo "ERROR: Script is not running as PID 1 (PID=$$)"
    exit 1
fi
echo "OK: Running as PID 1"

#################################################
# Verify mountpoints exist
#################################################
for dir in /data /backup; do
    if mountpoint -q "$dir"; then
        echo "OK: $dir is mounted"
    else
        echo "ERROR: $dir is NOT mounted"
        exit 1
    fi
done

#################################################
# Compare mount sources
#################################################
get_mount_source() {
    grep " $(readlink -f "$1") " /proc/self/mountinfo | \
    awk -F' - ' '{print $2}' | \
    awk '{print $2}'
}

src1=$(get_mount_source /data)
src2=$(get_mount_source /backup)

echo "Source /data: $src1"
echo "Source /backup: $src2"

if [ "$src1" = "$src2" ]; then
    echo "WARNING: Both mountpoints reference the same source!"
else
    echo "OK: Mountpoints reference different sources"
fi

#################################################
# Disk space check for expected backup
#################################################
expected=$(du -xsm "/data/uploads" | awk '{print $1}')
optimal=$(( 2*expected ))
avail=$(df -P -BM "/backup" | tail -1 | awk '{print $4}' | tr -d 'M')

echo ""
echo "Expected backup size:         ${expected}M"
echo "Optimal minimum storage size: ${optimal}M"
echo "Available storage size:       ${avail}M"

HUMHUB_DOCKER__BACKUP_MERGE_ARCHIVES=${HUMHUB_DOCKER__BACKUP_MERGE_ARCHIVES:-"true"}
if [ $expected -gt $avail ]; then
    echo "ERROR: Available backup storage too low!"
    exit 1
elif [ $optimal -gt $avail ]; then
    echo "WARNING: Available backup storage not sufficient for optimal backup! (disabling archive merge)"
    HUMHUB_DOCKER__BACKUP_MERGE_ARCHIVES="false"
else
    echo "OK: Available backup storage is sufficient"
fi

#################################################
# DSN availability and db connectivity check
#################################################

# --- Required variables check ---
: "${HUMHUB_CONFIG__COMPONENTS__DB__DSN:?DSN not set}"
: "${HUMHUB_CONFIG__COMPONENTS__DB__USERNAME:?DB user not set}"
: "${HUMHUB_CONFIG__COMPONENTS__DB__PASSWORD:?DB password not set}"

# --- Parse DSN ---
dsn="${HUMHUB_CONFIG__COMPONENTS__DB__DSN#mysql:}"

host="${dsn#*host=}"
host="${host%%;*}"

dbname="${dsn#*dbname=}"
dbname="${dbname%%;*}"

port="3306"
if [[ "$dsn" == *"port="* ]]; then
    port="${dsn#*port=}"
    port="${port%%;*}"
fi

# --- Validation ---
if [[ -z "$host" || -z "$dbname" ]]; then
    echo "ERROR: Invalid DSN: host or dbname is missing" >&2
    exit 1
fi

# --- Connectivity check ---
if ! output=$(mariadb \
        --connect-timeout=5 \
        -h "$host" \
        -P "$port" \
        -u "$HUMHUB_CONFIG__COMPONENTS__DB__USERNAME" \
        -p"$HUMHUB_CONFIG__COMPONENTS__DB__PASSWORD" \
        -D "$dbname" \
        -e "SELECT 1;" 2>&1); then
    echo "ERROR: Failed to connecting to database $host:$port / DB=$dbname" >&2
    echo "MariaDB connection error:" >&2
    echo "$output" >&2
    exit 1
fi

echo "OK: Database connection successful."

#################################################
# All checks successful
#################################################
echo ""
echo "All checks completed successfully."
echo "==== Backup Check Finished ===="

echo ""
echo "==== Backup Started  ===="
echo ""

echo -n " - mariadb-dump"
db_backup="humhub_db_`date +'%Y%m%d%H%M%S'`.sql.gz"
mariadb-dump -u "$HUMHUB_CONFIG__COMPONENTS__DB__USERNAME" \
             -p"$HUMHUB_CONFIG__COMPONENTS__DB__PASSWORD" \
             --default-character-set=utf8mb4 \
             --single-transaction \
             --skip-extended-insert \
             -h "$host" \
             -P "$port" \
             "$dbname" | gzip -9 > "/backup/$db_backup"
echo " ... OK"

echo -n " - storage-dump"
storage_backup="humhub_storage_backup_`date +'%Y%m%d%H%M%S'`.tar.gz"
cd /
tar czpf "/backup/$storage_backup" data/config/ data/modules/ data/modules-custom/ data/themes/ data/uploads/
echo " ... OK"

if [ "$HUMHUB_DOCKER__BACKUP_MERGE_ARCHIVES" = "true" ]; then
    echo -n " - backup-tar"
    final_backup="/backup/humhub_backup_`date +'%Y%m%d%H%M%S'`.tar"
    cd /backup
    tar cf "$final_backup" --remove-files "$db_backup" "$storage_backup"
    echo " ... OK"
else
    echo " - (skipping archive merge)"
fi

echo ""
echo "==== Backup Finished ===="
exit 0
