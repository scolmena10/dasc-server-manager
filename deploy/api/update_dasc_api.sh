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

if ! command -v git >/dev/null 2>&1 || ! command -v rsync >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  echo "==> Instalando dependencias del sistema necesarias"
  apt update
  apt install -y git rsync python3 python3-venv python3-pip
fi

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
  echo "ERROR: falta la clave SSH $DASC_KEY. Reinstala la API o vuelve a generar el SSH aislado."
  exit 1
fi

chown "$APP_USER:$APP_GROUP" "$DASC_KEY" "${DASC_KEY}.pub" 2>/dev/null || true
chmod 600 "$DASC_KEY"
[[ -f "${DASC_KEY}.pub" ]] && chmod 644 "${DASC_KEY}.pub"

BACKUP_HOST="$(awk -F= '/^BACKUPS_HOST=/{print $2}' "$INSTALL_DIR/config.env" | tail -n1 | tr -d '[:space:]' || true)"
if [[ -z "$BACKUP_HOST" ]]; then
  echo "ERROR: no se ha podido obtener BACKUPS_HOST desde config.env"
  exit 1
fi

echo "==> Asegurando known_hosts del SSH aislado"
if ! sudo -u "$APP_USER" ssh-keyscan -H "$BACKUP_HOST" > "$DASC_KNOWN_HOSTS" 2>/dev/null; then
  echo "ERROR: no se pudo regenerar $DASC_KNOWN_HOSTS con ssh-keyscan"
  exit 1
fi
chown "$APP_USER:$APP_GROUP" "$DASC_KNOWN_HOSTS"
chmod 644 "$DASC_KNOWN_HOSTS"

echo "==> Verificando SSH aislado"
sudo -u "$APP_USER" ssh \
  -i "$DASC_KEY" \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile="$DASC_KNOWN_HOSTS" \
  "dasc@${BACKUP_HOST}" "hostname >/dev/null" || {
    echo "ERROR: la verificación SSH del panel ha fallado."
    exit 1
  }

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
