#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="${SERVICE_NAME:-dasc-api}"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
INSTALL_DIR="${INSTALL_DIR:-/opt/dasc/api}"
VENV_DIR="${VENV_DIR:-${INSTALL_DIR}/venv}"
BRANCH="${BRANCH:-main}"

if [[ "$EUID" -ne 0 ]]; then
  echo "ERROR: ejecuta este script con sudo."
  exit 1
fi

if [[ ! -f "$SERVICE_FILE" ]]; then
  echo "ERROR: no existe el servicio ${SERVICE_NAME} en ${SERVICE_FILE}"
  exit 1
fi

# Intentamos obtener el usuario real del servicio systemd.
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

MISSING_PKGS=()
for cmd in git rsync python3; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    MISSING_PKGS+=("$cmd")
  fi
done

if [[ ! -x /usr/bin/python3 ]] || ! dpkg -s python3-venv >/dev/null 2>&1; then
  MISSING_PKGS+=("python3-venv")
fi

if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
  echo "==> Instalando dependencias del sistema necesarias"
  apt update
  apt install -y git rsync python3 python3-venv python3-pip
fi

echo "==> Update DASC API"
echo "    Servicio:     ${SERVICE_NAME}"
echo "    Usuario:      ${APP_USER}"
echo "    Repo:         ${REPO_DIR}"
echo "    Package:      ${PACKAGE_DIR}"
echo "    Instalación:  ${INSTALL_DIR}"
echo "    Rama:         ${BRANCH}"

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
  --exclude='data/alerts.db' \
  "$PACKAGE_DIR/" "$INSTALL_DIR/"

echo "==> Ajustando permisos de la instalación"
chown -R "$APP_USER:$APP_GROUP" "$INSTALL_DIR"
if [[ -f "$INSTALL_DIR/config.env" ]]; then
  chmod 640 "$INSTALL_DIR/config.env"
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
