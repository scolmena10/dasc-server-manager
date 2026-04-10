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

if [[ -z "$TYPE" || -z "$DB" || -z "$NAME" ]]; then
  echo "ERROR (400): Faltan parámetros. Uso: backups_api.sh <type> <db> <dest> <name> <compress> <retention> <base_ref> <notes>"
  exit 1
fi

mkdir -p "$DEST"
DATE="$(date +'%Y%m%d-%H%M%S')"

# Si el usuario dejó el placeholder YYYYMMDD o HHMM, lo sustituimos
SAFE_NAME="$NAME"
SAFE_NAME="${SAFE_NAME//YYYYMMDD/$(date +'%Y%m%d')}"
SAFE_NAME="${SAFE_NAME//HHMM/$(date +'%H%M')}"
SAFE_NAME="${SAFE_NAME//YYYYMMDD-HHMM/$(date +'%Y%m%d-%H%M')}"

OUTFILE="$DEST/$SAFE_NAME"

# MVP: Full real con mysqldump. Incremental/Diff: por ahora dump también (luego se mejora con binlogs)
# OJO: esto asume que en .30 existe acceso a MySQL y credenciales configuradas (por ~/.my.cnf o usuario/clave).
MYSQL_HOST="192.168.60.20"
mysqldump -h "$MYSQL_HOST" --protocol=tcp --single-transaction --databases "$DB" > "$OUTFILE"

if [[ "$COMPRESS" == "gzip" ]]; then
  gzip -f "$OUTFILE"
  OUTFILE="$OUTFILE.gz"
fi

# Retención (borrado de antiguos)
if [[ "$RETENTION" != "0" ]]; then
  find "$DEST" -type f -mtime +"$RETENTION" -name "*.sql*" -delete || true
fi

echo "OK: Backup $TYPE creado en $OUTFILE"
