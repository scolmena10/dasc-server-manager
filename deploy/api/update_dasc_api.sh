#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="${SERVICE_NAME:-dasc-api}"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
INSTALL_DIR="${INSTALL_DIR:-/opt/dasc/api}"
VENV_DIR="${VENV_DIR:-${INSTALL_DIR}/venv}"
BRANCH="${BRANCH:-main}"

DASC_SSH_DIR="${INSTALL_DIR}/.ssh"
DASC_KEY="${DASC_SSH_DIR}/id_rsa_dasc"
DASC_KNOWN_HOSTS="${DASC_SSH_DIR}/known_hosts_dasc"

if [[ "$EUID" -ne 0 ]]; then
  echo "ERROR: ejecuta este script con sudo."
  exit 1
fi

if [[ ! -f "$SERVICE_FILE" ]]; then
  echo "ERROR: no existe el servicio ${SERVICE_NAME} en ${SERVICE_FILE}"
  exit 1
fi

APP_USER="$(awk -F= '/^User=/{print $2}' "$SERVICE_FILE" | tail -n1 | tr -d '[:space:]')"
if [[ -z "$APP_USER" ]]; then
  APP_USER="${SUDO_USER:-$USER}"
fi
APP_GROUP="$APP_USER"

REPO_DIR="${REPO_DIR:-/home/${APP_USER}/dasc-server-manager}"
PACKAGE_DIR="${PACKAGE_DIR:-${REPO_DIR}/deploy/api/package}"

if [[ ! -d "$REPO_DIR/.git" ]]; then
  echo "ERROR: no existe un repositorio Git válido en $REPO_DIR"
  exit 1
fi

if [[ ! -d "$INSTALL_DIR" ]]; then
  echo "ERROR: no existe la instalación en $INSTALL_DIR"
  exit 1
fi

if [[ ! -d "$PACKAGE_DIR" ]]; then
  echo "ERROR: no existe la carpeta package en $PACKAGE_DIR"
  exit 1
fi

for required in main.py requirements.txt templates static; do
  if [[ ! -e "$PACKAGE_DIR/$required" ]]; then
    echo "ERROR: falta $required dentro de $PACKAGE_DIR"
    exit 1
  fi
done

echo "==> Instalando dependencias del sistema necesarias"
apt update
DEBIAN_FRONTEND=noninteractive apt install -y \
  git \
  rsync \
  python3 \
  python3-venv \
  python3-pip \
  openssh-client \
  sshpass \
  curl

echo "==> Update DASC API"
echo " Servicio: ${SERVICE_NAME}"
echo " Usuario: ${APP_USER}"
echo " Repo: ${REPO_DIR}"
echo " Package: ${PACKAGE_DIR}"
echo " Instalación: ${INSTALL_DIR}"
echo " Rama: ${BRANCH}"

echo "==> Actualizando código desde GitHub (${BRANCH})"
git -C "$REPO_DIR" fetch --all --prune

if [[ -n "$(git -C "$REPO_DIR" status --porcelain)" ]]; then
  echo "==> Aviso: hay cambios locales en el repo del servidor; se descartarán para dejarlo alineado con origin/${BRANCH}"
fi

git -C "$REPO_DIR" reset --hard "origin/${BRANCH}"

echo "==> Sincronizando archivos del panel"
rsync -av --delete \
  --exclude='config.env' \
  --exclude='data/users.json' \
  --exclude='data/*.db' \
  --exclude='data/auth_logs.json' \
  --exclude='.ssh' \
  "$PACKAGE_DIR/" "$INSTALL_DIR/"

echo "==> Ajustando permisos de la instalación"
chown -R "$APP_USER:$APP_GROUP" "$INSTALL_DIR"
if [[ -f "$INSTALL_DIR/config.env" ]]; then
  chmod 640 "$INSTALL_DIR/config.env"
fi

mkdir -p "$DASC_SSH_DIR"
chown "$APP_USER:$APP_GROUP" "$DASC_SSH_DIR"
chmod 700 "$DASC_SSH_DIR"

if [[ ! -f "$DASC_KEY" ]]; then
  echo "==> No existe la clave SSH aislada. Se generará una nueva en $DASC_KEY"
  sudo -u "$APP_USER" ssh-keygen -t rsa -b 4096 -N "" -f "$DASC_KEY"
fi

if [[ ! -f "${DASC_KEY}.pub" ]]; then
  echo "==> Regenerando clave pública ${DASC_KEY}.pub"
  sudo -u "$APP_USER" ssh-keygen -y -f "$DASC_KEY" > "${DASC_KEY}.pub"
fi

chown "$APP_USER:$APP_GROUP" "$DASC_KEY" "${DASC_KEY}.pub"
chmod 600 "$DASC_KEY"
chmod 644 "${DASC_KEY}.pub"

BACKUP_HOST="$(awk -F= '/^BACKUPS_HOST=/{print $2}' "$INSTALL_DIR/config.env" | tail -n1 | tr -d '[:space:]' || true)"
if [[ -z "$BACKUP_HOST" ]]; then
  echo "ERROR: no se ha podido obtener BACKUPS_HOST desde config.env"
  exit 1
fi

DATABASE_HOST="$(awk -F= '/^TERMINAL_DATABASE_HOST=/{print $2}' "$INSTALL_DIR/config.env" | tail -n1 | tr -d '[:space:]' || true)"
if [[ -z "$DATABASE_HOST" ]]; then
  DATABASE_HOST="$(awk -F= '/^LOGS_DB_HOST=/{print $2}' "$INSTALL_DIR/config.env" | tail -n1 | tr -d '[:space:]' || true)"
fi

HOSTS_TO_CHECK=("$BACKUP_HOST")
if [[ -n "$DATABASE_HOST" && "$DATABASE_HOST" != "$BACKUP_HOST" ]]; then
  HOSTS_TO_CHECK+=("$DATABASE_HOST")
fi

echo "==> Asegurando known_hosts del SSH aislado"
: > "$DASC_KNOWN_HOSTS"
chown "$APP_USER:$APP_GROUP" "$DASC_KNOWN_HOSTS"
chmod 644 "$DASC_KNOWN_HOSTS"

for TARGET_HOST in "${HOSTS_TO_CHECK[@]}"; do
  echo "==> Registrando host key de ${TARGET_HOST}"
  if ! sudo -u "$APP_USER" ssh-keyscan -H "$TARGET_HOST" >> "$DASC_KNOWN_HOSTS" 2>/dev/null; then
    echo "ERROR: no se pudo obtener host key de ${TARGET_HOST}"
    echo "Revisa que esa máquina esté encendida, tenga red y tenga SSH activo."
    exit 1
  fi
done

chown "$APP_USER:$APP_GROUP" "$DASC_KNOWN_HOSTS"
chmod 644 "$DASC_KNOWN_HOSTS"

ensure_ssh_access() {
  local TARGET_HOST="$1"
  local TARGET_LABEL="$2"
  local ENV_PASS_NAME="$3"
  local TARGET_PASS="${!ENV_PASS_NAME:-}"

  echo "==> Verificando SSH contra ${TARGET_LABEL} (${TARGET_HOST})"

  if sudo -u "$APP_USER" ssh \
    -i "$DASC_KEY" \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="$DASC_KNOWN_HOSTS" \
    "dasc@${TARGET_HOST}" "hostname >/dev/null"; then
    echo "==> SSH OK contra ${TARGET_LABEL} (${TARGET_HOST})"
    return 0
  fi

  echo "AVISO: SSH con clave ha fallado contra ${TARGET_LABEL} (${TARGET_HOST})."
  echo "==> Se intentará copiar la clave pública automáticamente con sshpass/ssh-copy-id."

  if [[ -z "$TARGET_PASS" ]]; then
    echo
    read -rsp "Introduce la contraseña actual de dasc en ${TARGET_LABEL} (${TARGET_HOST}): " TARGET_PASS
    echo
  fi

  if [[ -z "$TARGET_PASS" ]]; then
    echo "ERROR: la contraseña de dasc para ${TARGET_LABEL} no puede estar vacía."
    exit 1
  fi

  sudo -u "$APP_USER" sshpass -p "$TARGET_PASS" ssh-copy-id \
    -i "${DASC_KEY}.pub" \
    -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="$DASC_KNOWN_HOSTS" \
    "dasc@${TARGET_HOST}" || {
      echo "ERROR: no se pudo copiar la clave automáticamente a dasc@${TARGET_HOST}."
      echo "Revisa que el usuario dasc exista, que la contraseña sea correcta y que PasswordAuthentication esté activo."
      exit 1
    }

  echo "==> Verificando de nuevo SSH contra ${TARGET_LABEL} (${TARGET_HOST})"
  sudo -u "$APP_USER" ssh \
    -i "$DASC_KEY" \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="$DASC_KNOWN_HOSTS" \
    "dasc@${TARGET_HOST}" "hostname >/dev/null" || {
      echo "ERROR: la verificación SSH sigue fallando contra ${TARGET_LABEL} (${TARGET_HOST})."
      exit 1
    }

  echo "==> SSH configurado correctamente contra ${TARGET_LABEL} (${TARGET_HOST})"
}

echo "==> Verificando/auto-configurando SSH aislado"
ensure_ssh_access "$BACKUP_HOST" "servidor de backups" "DASC_BACKUP_PASS"

if [[ -n "$DATABASE_HOST" && "$DATABASE_HOST" != "$BACKUP_HOST" ]]; then
  ensure_ssh_access "$DATABASE_HOST" "servidor de base de datos" "DASC_DB_PASS"
fi

recreate_venv="0"
if [[ ! -d "$VENV_DIR" ]]; then
  echo "==> No existe el entorno virtual. Se creará de nuevo"
  recreate_venv="1"
elif [[ ! -x "$VENV_DIR/bin/python" ]]; then
  echo "==> El entorno virtual existe pero está roto. Se recreará"
  recreate_venv="1"
fi

if [[ "$recreate_venv" == "1" ]]; then
  rm -rf "$VENV_DIR"
  sudo -u "$APP_USER" python3 -m venv "$VENV_DIR"
fi

echo "==> Actualizando herramientas base del entorno virtual"
sudo -u "$APP_USER" "$VENV_DIR/bin/python" -m pip install --upgrade pip setuptools wheel

echo "==> Instalando dependencias Python"
sudo -u "$APP_USER" "$VENV_DIR/bin/python" -m pip install -r "$INSTALL_DIR/requirements.txt"

if [[ ! -x "$VENV_DIR/bin/uvicorn" ]]; then
  echo "ERROR: no existe $VENV_DIR/bin/uvicorn después de instalar dependencias"
  exit 1
fi

echo "==> Comprobando imports mínimos"
sudo -u "$APP_USER" "$VENV_DIR/bin/python" -c "import fastapi, uvicorn; print('Imports OK')"

echo "==> Recargando systemd"
systemctl daemon-reload

echo "==> Reiniciando servicio"
systemctl restart "$SERVICE_NAME"

echo "==> Estado del servicio"
systemctl --no-pager --full status "$SERVICE_NAME" || true

echo "==> Comprobando respuesta local"
curl -I --max-time 5 http://127.0.0.1:8000 || true

echo "==> Update completado correctamente"
