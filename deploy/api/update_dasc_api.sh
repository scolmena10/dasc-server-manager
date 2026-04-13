#!/usr/bin/env bash
set -euo pipefail

APP_USER="${SUDO_USER:-$USER}"
REPO_DIR="${REPO_DIR:-/home/${APP_USER}/dasc-server-manager}"
INSTALL_DIR="/opt/dasc/api"
SERVICE_NAME="dasc-api"
BRANCH="${BRANCH:-main}"

if [[ "$EUID" -ne 0 ]]; then
  echo "ERROR: ejecuta este script con sudo."
  exit 1
fi

if [[ ! -d "$REPO_DIR/.git" ]]; then
  echo "ERROR: no existe un repositorio Git válido en $REPO_DIR"
  exit 1
fi

if [[ ! -d "$INSTALL_DIR" ]]; then
  echo "ERROR: no existe la instalación en $INSTALL_DIR"
  exit 1
fi

if ! command -v rsync >/dev/null 2>&1; then
  echo "==> Instalando rsync"
  apt update
  apt install -y rsync
fi

echo "==> Actualizando código desde GitHub (${BRANCH})"
git -C "$REPO_DIR" fetch --all --prune

if [[ -n "$(git -C "$REPO_DIR" status --porcelain)" ]]; then
  echo "==> Aviso: hay cambios locales en el repo del servidor; se descartarán para dejarlo alineado con origin/${BRANCH}"
fi

git -C "$REPO_DIR" reset --hard "origin/${BRANCH}"

echo "==> Actualizando archivos del panel"
rsync -av --delete --exclude=config.env --exclude=data/users.json "$REPO_DIR/deploy/api/package/" "$INSTALL_DIR/"

echo "==> Instalando dependencias Python"
"$INSTALL_DIR/venv/bin/pip" install -r "$INSTALL_DIR/requirements.txt"

echo "==> Reiniciando servicio"
systemctl restart "$SERVICE_NAME"

echo "==> Estado del servicio"
systemctl --no-pager --full status "$SERVICE_NAME" || true

echo "==> Update completado"
