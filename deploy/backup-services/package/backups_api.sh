#!/bin/bash
set -euo pipefail

TYPE="${1:-}"
DB="${2:-}"
DEST="${3:-/var/backups/dasc}"
NAME="${4:-}"
COMPRESS="${5:-gzip}"      # gzip | none
RETENTION="${6:-7}"        # días
BASE_REF="${7:-}"          # (MVP: lo recibimos aunque no lo usemos)
NOTES="${8:-}"             # (MVP: lo recibimos aunque no lo usemos)
MYSQL_DEFAULTS_FILE="${MYSQL_DEFAULTS_FILE:-$HOME/.my.cnf}"

if [[ -z "$TYPE" || -z "$DB" || -z "$NAME" ]]; then
  echo "ERROR (400): Faltan parámetros. Uso: backups_api.sh <type> <db> <dest> <name> <compress> <retention> <base_ref> <notes>"
  exit 1
fi

if [[ "$TYPE" != "full" && "$TYPE" != "incremental" && "$TYPE" != "differential" ]]; then
  echo "ERROR (400): Tipo de backup no válido: $TYPE"
  exit 1
fi

mkdir -p "$DEST"

SAFE_NAME="$NAME"
SAFE_NAME="${SAFE_NAME//YYYYMMDD-HHMM/$(date +'%Y%m%d-%H%M')}"
SAFE_NAME="${SAFE_NAME//YYYYMMDD/$(date +'%Y%m%d')}"
SAFE_NAME="${SAFE_NAME//HHMM/$(date +'%H%M')}"

OUTFILE="$DEST/$SAFE_NAME"

MYSQL_ARGS=(--protocol=tcp --single-transaction --routines --events --triggers --databases "$DB")
if [[ -f "$MYSQL_DEFAULTS_FILE" ]]; then
  MYSQL_ARGS=(--defaults-extra-file="$MYSQL_DEFAULTS_FILE" "${MYSQL_ARGS[@]}")
fi

mysqldump "${MYSQL_ARGS[@]}" > "$OUTFILE"

if [[ "$COMPRESS" == "gzip" ]]; then
  gzip -f "$OUTFILE"
  OUTFILE="$OUTFILE.gz"
fi

if [[ "$RETENTION" != "0" ]]; then
  find "$DEST" -type f -mtime +"$RETENTION" -name "*.sql*" -delete || true
fi

echo "OK: Backup $TYPE creado en $OUTFILE"
