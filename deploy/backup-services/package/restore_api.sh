#!/usr/bin/env bash
set -euo pipefail

TARGET_ID="${1:-}"
DEST="${2:-/home/dasc/backups}"
CONFIRM="${3:-SI}"

MYSQL_HOST="${MYSQL_HOST:-192.168.60.20}"
MYSQL_PORT="${MYSQL_PORT:-3306}"

RUN_USER="$(id -un)"
RUN_HOME="$(getent passwd "$RUN_USER" | cut -d: -f6)"
MY_RESTORE_CNF="${MY_RESTORE_CNF:-${RUN_HOME}/.my_restore.cnf}"

META_DIR="${DEST}/.dasc"
HISTORY_FILE="${META_DIR}/history.tsv"
LOCK_FILE="${META_DIR}/restore.lock"
PRESTORE_DIR="${DEST}/pre-restore"

find_cmd() {
  for cmd in "$@"; do
    if command -v "$cmd" >/dev/null 2>&1; then
      command -v "$cmd"
      return 0
    fi
  done
  return 1
}

MYSQL_CMD="$(find_cmd mariadb mysql || true)"
DUMP_CMD="$(find_cmd mariadb-dump mysqldump || true)"

if [[ -z "$TARGET_ID" || ! "$TARGET_ID" =~ ^[0-9]+$ ]]; then
  echo "ERROR: Debes indicar un ID numérico de backup para restaurar."
  exit 1
fi

if [[ "$CONFIRM" != "SI" ]]; then
  echo "ERROR: Restauración cancelada."
  exit 1
fi

if [[ -z "$MYSQL_CMD" ]]; then
  echo "ERROR: No se encuentra mariadb/mysql en el servidor de backups."
  exit 1
fi

if [[ -z "$DUMP_CMD" ]]; then
  echo "ERROR: No se encuentra mariadb-dump/mysqldump en el servidor de backups."
  exit 1
fi

if [[ ! -f "$MY_RESTORE_CNF" ]]; then
  echo "ERROR: No existe $MY_RESTORE_CNF. Revisa install_backup_services.sh."
  exit 1
fi

if [[ ! -f "$HISTORY_FILE" ]]; then
  echo "ERROR: No existe el historial $HISTORY_FILE."
  exit 1
fi

mkdir -p "$META_DIR" "$PRESTORE_DIR"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "ERROR: Ya hay otra restauración en ejecución."
  exit 1
fi

mysql_args=(
  --defaults-extra-file="$MY_RESTORE_CNF"
  --protocol=tcp
  -h "$MYSQL_HOST"
  -P "$MYSQL_PORT"
)

get_line_by_id() {
  local id="$1"
  awk -F'\t' -v id="$id" 'NR > 1 && $1 == id { print; exit }' "$HISTORY_FILE"
}

field_from_line() {
  local line="$1"
  local pos="$2"
  awk -F'\t' -v p="$pos" '{ print $p }' <<< "$line"
}

validate_file_path() {
  local f="$1"

  case "$f" in
    /home/dasc/backups/*)
      ;;
    *)
      echo "ERROR: Ruta no permitida en historial: $f"
      exit 1
      ;;
  esac

  if [[ ! -f "$f" ]]; then
    echo "ERROR: No existe el archivo de backup: $f"
    exit 1
  fi
}

apply_sql_file() {
  local f="$1"

  validate_file_path "$f"

  echo "==> Aplicando archivo: $f"

  if [[ "$f" == *.gz ]]; then
    gzip -dc -- "$f" | "$MYSQL_CMD" "${mysql_args[@]}"
  else
    "$MYSQL_CMD" "${mysql_args[@]}" < "$f"
  fi
}

TARGET_LINE="$(get_line_by_id "$TARGET_ID")"

if [[ -z "$TARGET_LINE" ]]; then
  echo "ERROR: No existe ningún backup con ID=$TARGET_ID."
  exit 1
fi

reverse_chain=()
visited=" "
current_id="$TARGET_ID"

while true; do
  if [[ "$visited" == *" $current_id "* ]]; then
    echo "ERROR: Ciclo detectado en el historial al procesar ID=$current_id."
    exit 1
  fi

  visited+="$current_id "

  line="$(get_line_by_id "$current_id")"

  if [[ -z "$line" ]]; then
    echo "ERROR: La cadena de restauración está rota. Falta ID=$current_id."
    exit 1
  fi

  reverse_chain+=("$line")

  type="$(field_from_line "$line" 3)"

  if [[ "$type" == "full" ]]; then
    break
  fi

  base_id="$(field_from_line "$line" 6)"

  if [[ -z "$base_id" ]]; then
    echo "ERROR: El backup ID=$current_id no es completo y no tiene base_id."
    exit 1
  fi

  current_id="$base_id"
done

chain=()
for (( idx=${#reverse_chain[@]}-1 ; idx>=0 ; idx-- )); do
  chain+=("${reverse_chain[$idx]}")
done

FULL_LINE="${chain[0]}"
DB="$(field_from_line "$FULL_LINE" 4)"

if [[ -z "$DB" || ! "$DB" =~ ^[A-Za-z0-9_]+$ ]]; then
  echo "ERROR: Nombre de base de datos no válido en historial: $DB"
  exit 1
fi

for line in "${chain[@]}"; do
  id="$(field_from_line "$line" 1)"
  db_line="$(field_from_line "$line" 4)"
  file="$(field_from_line "$line" 5)"

  if [[ "$db_line" != "$DB" ]]; then
    echo "ERROR: La cadena mezcla bases de datos diferentes. ID=$id DB=$db_line esperado=$DB"
    exit 1
  fi

  validate_file_path "$file"
done

PRE_FILE="${PRESTORE_DIR}/pre-restore-${DB}-before-${TARGET_ID}-$(date +'%Y%m%d-%H%M%S').sql.gz"

echo "==> Creando copia preventiva antes de restaurar: $PRE_FILE"

"$DUMP_CMD" "${mysql_args[@]}" \
  --single-transaction \
  --quick \
  --routines \
  --triggers \
  --events \
  --databases "$DB" | gzip -c > "$PRE_FILE" || {
    echo "ERROR: No se pudo crear la copia preventiva. Restauración abortada."
    exit 1
  }

echo "==> Reiniciando base de datos $DB"

"$MYSQL_CMD" "${mysql_args[@]}" -e "DROP DATABASE IF EXISTS \`$DB\`; CREATE DATABASE \`$DB\`;"

for line in "${chain[@]}"; do
  id="$(field_from_line "$line" 1)"
  type="$(field_from_line "$line" 3)"
  file="$(field_from_line "$line" 5)"

  echo "==> Restaurando ID=$id tipo=$type"
  apply_sql_file "$file"
done

ids=""
for line in "${chain[@]}"; do
  ids+="$(field_from_line "$line" 1) "
done
ids="${ids% }"

echo "OK: Restauración completada hasta ID=$TARGET_ID | BD=$DB | cadena=$ids | copia_previa=$PRE_FILE"
