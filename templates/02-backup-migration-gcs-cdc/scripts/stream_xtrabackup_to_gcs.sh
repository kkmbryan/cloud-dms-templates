#!/usr/bin/env bash
# ==============================================================================
# Self-Managed GCE MySQL 8.0 -> GCS Streaming Percona XtraBackup Script
# ==============================================================================
# Streams a hot, non-blocking physical backup from a GCE MySQL 8.0 instance (or
# read replica) directly to a Google Cloud Storage (GCS) staging bucket for
# Cloud DMS Scenario 2 (Backup in GCS + Continuous Binlog CDC).
#
# Usage:
#   export MYSQL_USER="dms_backup_user"
#   export MYSQL_PASSWORD="your_secure_password"
#   export BUCKET_NAME="prod-dms-mysql80-staging-sg"
#   export BACKUP_OBJECT_PATH="backups/mysql80-full.xbstream"
#   ./stream_xtrabackup_to_gcs.sh
# ==============================================================================

set -euo pipefail

MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_DATADIR="${MYSQL_DATADIR:-/var/lib/mysql}"
PARALLEL_THREADS="${PARALLEL_THREADS:-4}"
LOG_DIR="${LOG_DIR:-/var/log/dms-mysql-backup}"

if [[ -z "${BUCKET_NAME:-}" ]]; then
  echo "[ERROR] BUCKET_NAME environment variable is required (e.g., prod-dms-mysql80-staging-sg)." >&2
  exit 1
fi

if [[ -z "${BACKUP_OBJECT_PATH:-}" ]]; then
  echo "[ERROR] BACKUP_OBJECT_PATH environment variable is required (e.g., backups/mysql80-full.xbstream)." >&2
  exit 1
fi

if [[ -z "${MYSQL_PASSWORD:-}" ]]; then
  echo "[ERROR] MYSQL_PASSWORD environment variable is required." >&2
  exit 1
fi

for cmd in xtrabackup gcloud; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "[ERROR] Required command '${cmd}' is not installed or not in PATH." >&2
    exit 1
  fi
done

mkdir -p "${LOG_DIR}"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
XTRABACKUP_LOG="${LOG_DIR}/xtrabackup-${TIMESTAMP}.log"
GTID_INFO_FILE="${LOG_DIR}/xtrabackup-gtid-coordinates-${TIMESTAMP}.txt"
GCS_URI="gs://${BUCKET_NAME}/${BACKUP_OBJECT_PATH}"

echo "=============================================================================="
echo "[INFO] Starting non-blocking Percona XtraBackup 8.0 stream to GCS"
echo "[INFO] Source MySQL : ${MYSQL_HOST}:${MYSQL_PORT} (datadir: ${MYSQL_DATADIR})"
echo "[INFO] Target GCS   : ${GCS_URI}"
echo "[INFO] Log File     : ${XTRABACKUP_LOG}"
echo "=============================================================================="

# Run Percona XtraBackup 8.0 in streaming mode and pipe directly to GCS
xtrabackup \
  --backup \
  --host="${MYSQL_HOST}" \
  --port="${MYSQL_PORT}" \
  --user="${MYSQL_USER}" \
  --password="${MYSQL_PASSWORD}" \
  --datadir="${MYSQL_DATADIR}" \
  --stream=xbstream \
  --compress \
  --parallel="${PARALLEL_THREADS}" \
  --no-server-version-check \
  2> "${XTRABACKUP_LOG}" \
  | gcloud storage cp - "${GCS_URI}"

echo "[INFO] Backup stream upload completed. Verifying XtraBackup completion status..."

if ! grep -q "completed OK!" "${XTRABACKUP_LOG}"; then
  echo "[ERROR] Percona XtraBackup did not report 'completed OK!'. Inspect ${XTRABACKUP_LOG}." >&2
  exit 1
fi

# Extract binlog / GTID coordinates recorded by XtraBackup for audit verification
grep -E "MySQL binlog position:|GTID of the last change" "${XTRABACKUP_LOG}" | tee "${GTID_INFO_FILE}" || true

# Upload GTID coordinate metadata alongside the backup artifact
gcloud storage cp "${GTID_INFO_FILE}" "gs://${BUCKET_NAME}/${BACKUP_OBJECT_PATH}.gtid.txt"

echo "=============================================================================="
echo "[SUCCESS] Physical backup streamed to ${GCS_URI}"
echo "[SUCCESS] GTID metadata uploaded to ${GCS_URI}.gtid.txt"
echo "=============================================================================="
