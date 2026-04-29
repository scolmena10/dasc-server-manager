#!/usr/bin/env bash
set -euo pipefail

TYPE="${1:-}"
DB="${2:-}"
DEST="${3:-/home/dasc/backups}"
NAME="${4:-backup-YYYYMMDD-HHMM.sql}"
COMPRESS="${5:-gzip}"
RETENTION="${6:-0}"
BASE_REF="${7:-}"
NOTES="${8:-}"

MYSQL_HOST="${MYSQL_HOST:-192.168.60.20}"
MYSQL_PORT="${MYSQL_PORT:-3306}"

RUN_USER="$(id -un)"
RUN_HOME="$(getent passwd "$RUN_USER" | cut -d: -f6)"
MYCNF="${MYCNF:-${RUN_HOME}/.my.cnf}"

META_DIR="${DEST}/.dasc"
HISTORY_FILE="${META_DIR}/history.tsv"
LOCK_FILE="${META_DIR}/backup.lock"

find_cmd() {
  for cmd in "$@"; do
    if command -v "$cmd" >/dev/null 2>&1; then
      command -v "$cmd"
      return 0
    fi
  done
  return 1
}

if [[ -z "$TYPE" || -z "$DB" || -z "$NAME" ]]; then
  echo "ERROR (400): Faltan parámetros. Uso: backups_api.sh <type> <db> <dest> <name> <compress> <retention> <base_ref> <notes>"
  exit 1
fi

if [[ "$TYPE" != "full" && "$TYPE" != "incremental" && "$TYPE" != "differential" ]]; then
  echo "ERROR (400): Tipo de backup no válido: $TYPE"
  exit 1
fi

if [[ "$COMPRESS" != "gzip" && "$COMPRESS" != "none" ]]; then
  echo "ERROR (400): Compresión no válida: $COMPRESS"
  exit 1
fi

mkdir -p "$DEST" "$META_DIR"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "ERROR: Ya hay otro backup en ejecución."
  exit 1
fi

MYSQL_CMD="$(find_cmd mariadb mysql || true)"
DUMP_CMD="$(find_cmd mariadb-dump mysqldump || true)"
BINLOG_CMD="$(find_cmd mariadb-binlog mysqlbinlog || true)"

if [[ -z "$MYSQL_CMD" ]]; then
  echo "ERROR: No se encuentra mariadb/mysql en el servidor de backups."
  exit 1
fi

if [[ -z "$DUMP_CMD" ]]; then
  echo "ERROR: No se encuentra mariadb-dump/mysqldump en el servidor de backups."
  exit 1
fi

if [[ -z "$BINLOG_CMD" ]]; then
  echo "ERROR: No se encuentra mariadb-binlog/mysqlbinlog en el servidor de backups."
  exit 1
fi

if [[ ! -f "$MYCNF" ]]; then
  echo "ERROR: No existe $MYCNF. Revisa el instalador del servidor de backups."
  exit 1
fi

mysql_base_args=(
  --defaults-extra-file="$MYCNF"
  --protocol=tcp
  -h "$MYSQL_HOST"
  -P "$MYSQL_PORT"
)

mysql_batch_args=(
  "${mysql_base_args[@]}"
  --batch
  --skip-column-names
)

init_history() {
  if [[ ! -f "$HISTORY_FILE" ]]; then
    printf "id\tcreated_at\ttype\tdb\tfile\tbase_id\tstart_file\tstart_pos\tend_file\tend_pos\tnotes\n" > "$HISTORY_FILE"
  fi
}

safe_name() {
  local n="$1"
  n="${n//YYYYMMDD-HHMMSS/$(date +'%Y%m%d-%H%M%S')}"
  n="${n//YYYYMMDD-HHMM/$(date +'%Y%m%d-%H%M')}"
  n="${n//YYYYMMDD/$(date +'%Y%m%d')}"
  n="${n//HHMMSS/$(date +'%H%M%S')}"
  n="${n//HHMM/$(date +'%H%M')}"
  echo "$n"
}

get_master_status() {
  "$MYSQL_CMD" "${mysql_batch_args[@]}" -e "SHOW MASTER STATUS;" | awk 'NR==1 {print $1 "\t" $2}'
}

get_binary_logs() {
  "$MYSQL_CMD" "${mysql_batch_args[@]}" -e "SHOW BINARY LOGS;" | awk '{print $1}'
}

last_backup_line() {
  awk -F'\t' -v db="$DB" 'NR > 1 && $4 == db && $9 != "" && $10 != "" { line=$0 } END { print line }' "$HISTORY_FILE"
}

last_full_line() {
  awk -F'\t' -v db="$DB" 'NR > 1 && $3 == "full" && $4 == db && $9 != "" && $10 != "" { line=$0 } END { print line }' "$HISTORY_FILE"
}

next_id() {
  awk -F'\t' 'NR > 1 && $1 ~ /^[0-9]+$/ && $1 > max { max=$1 } END { print max + 1 }' "$HISTORY_FILE"
}

append_history() {
  local id="$1"
  local created_at="$2"
  local type="$3"
  local db="$4"
  local file="$5"
  local base_id="$6"
  local start_file="$7"
  local start_pos="$8"
  local end_file="$9"
  local end_pos="${10}"
  local notes="${11}"

  notes="${notes//$'\t'/ }"
  notes="${notes//$'\n'/ }"

  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$id" "$created_at" "$type" "$db" "$file" "$base_id" "$start_file" "$start_pos" "$end_file" "$end_pos" "$notes" >> "$HISTORY_FILE"
}

compress_if_needed() {
  local f="$1"

  if [[ "$COMPRESS" == "gzip" ]]; then
    gzip -f "$f"
    echo "${f}.gz"
  else
    echo "$f"
  fi
}

dump_binlogs_range() {
  local start_file="$1"
  local start_pos="$2"
  local end_file="$3"
  local end_pos="$4"
  local outfile="$5"

  mapfile -t logs < <(get_binary_logs)

  if [[ "${#logs[@]}" -eq 0 ]]; then
    echo "ERROR: No hay binary logs disponibles."
    exit 1
  fi

  local in_range=0
  : > "$outfile"

  for log in "${logs[@]}"; do
    if [[ "$log" == "$start_file" ]]; then
      in_range=1
    fi

    if [[ "$in_range" -ne 1 ]]; then
      continue
    fi

    binlog_args=(
      --defaults-extra-file="$MYCNF"
      --read-from-remote-server
      --host="$MYSQL_HOST"
      --port="$MYSQL_PORT"
      --database="$DB"
    )

    if [[ "$log" == "$start_file" && "$log" == "$end_file" ]]; then
      binlog_args+=(--start-position="$start_pos" --stop-position="$end_pos")
    elif [[ "$log" == "$start_file" ]]; then
      binlog_args+=(--start-position="$start_pos")
    elif [[ "$log" == "$end_file" ]]; then
      binlog_args+=(--stop-position="$end_pos")
    fi

    # mysqlbinlog contra MariaDB puede imprimir avisos de versión por stderr,
    # pero normalmente genera igualmente el contenido del binlog.
    "$BINLOG_CMD" "${binlog_args[@]}" "$log" >> "$outfile" || true
    echo "" >> "$outfile"

    if [[ "$log" == "$end_file" ]]; then
      break
    fi
  done
}

init_history

SAFE_NAME="$(safe_name "$NAME")"

if [[ "$TYPE" == "full" ]]; then
  OUTFILE="${DEST}/${SAFE_NAME}"

  echo "==> Ejecutando backup completo de ${DB}"

  "$DUMP_CMD" \
    --defaults-extra-file="$MYCNF" \
    --protocol=tcp \
    -h "$MYSQL_HOST" \
    -P "$MYSQL_PORT" \
    --single-transaction \
    --quick \
    --routines \
    --triggers \
    --events \
    --master-data=2 \
    --flush-logs \
    --databases "$DB" > "$OUTFILE"

  STATUS="$(get_master_status)"
  END_FILE="$(echo "$STATUS" | awk '{print $1}')"
  END_POS="$(echo "$STATUS" | awk '{print $2}')"

  if [[ -z "$END_FILE" || -z "$END_POS" ]]; then
    echo "ERROR: No se pudo obtener SHOW MASTER STATUS. ¿Están activos los binlogs?"
    exit 1
  fi

  OUTFILE="$(compress_if_needed "$OUTFILE")"

  ID="$(next_id)"
  CREATED_AT="$(date +'%Y-%m-%d %H:%M:%S')"

  append_history "$ID" "$CREATED_AT" "$TYPE" "$DB" "$OUTFILE" "" "" "" "$END_FILE" "$END_POS" "$NOTES"

  if [[ "$RETENTION" != "0" ]]; then
    find "$DEST" -maxdepth 1 -type f -mtime +"$RETENTION" -name "*.sql*" -delete || true
  fi

  echo "OK: Backup full creado en $OUTFILE | ID=$ID | binlog=${END_FILE}:${END_POS}"
  exit 0
fi

if [[ "$TYPE" == "incremental" ]]; then
  BASE_LINE="$(last_backup_line)"

  if [[ -z "$BASE_LINE" ]]; then
    echo "ERROR: No existe backup base. Primero ejecuta un backup completo."
    exit 1
  fi
else
  BASE_LINE="$(last_full_line)"

  if [[ -z "$BASE_LINE" ]]; then
    echo "ERROR: No existe backup completo base. Primero ejecuta un backup full."
    exit 1
  fi
fi

BASE_ID="$(echo "$BASE_LINE" | awk -F'\t' '{print $1}')"
START_FILE="$(echo "$BASE_LINE" | awk -F'\t' '{print $9}')"
START_POS="$(echo "$BASE_LINE" | awk -F'\t' '{print $10}')"

STATUS="$(get_master_status)"
END_FILE="$(echo "$STATUS" | awk '{print $1}')"
END_POS="$(echo "$STATUS" | awk '{print $2}')"

if [[ -z "$START_FILE" || -z "$START_POS" || -z "$END_FILE" || -z "$END_POS" ]]; then
  echo "ERROR: No se pudieron calcular posiciones de binlog."
  exit 1
fi

OUTFILE="${DEST}/${SAFE_NAME}"

echo "==> Ejecutando backup ${TYPE} de ${DB}"
echo "==> Desde ${START_FILE}:${START_POS} hasta ${END_FILE}:${END_POS}"

dump_binlogs_range "$START_FILE" "$START_POS" "$END_FILE" "$END_POS" "$OUTFILE"

OUTFILE="$(compress_if_needed "$OUTFILE")"

ID="$(next_id)"
CREATED_AT="$(date +'%Y-%m-%d %H:%M:%S')"

append_history "$ID" "$CREATED_AT" "$TYPE" "$DB" "$OUTFILE" "$BASE_ID" "$START_FILE" "$START_POS" "$END_FILE" "$END_POS" "$NOTES"

if [[ "$RETENTION" != "0" ]]; then
  find "$DEST" -maxdepth 1 -type f -mtime +"$RETENTION" -name "*.sql*" -delete || true
fi

echo "OK: Backup ${TYPE} creado en $OUTFILE | ID=$ID | base=$BASE_ID | rango=${START_FILE}:${START_POS}-${END_FILE}:${END_POS}"
