#!/usr/bin/env bash
set -e

REPO_DIR="/home/${SUDO_USER}/dasc-server-manager"
INSTALL_DIR="/opt/dasc/api"
SERVICE_NAME="dasc-api"

echo "==> Actualizando código desde GitHub"
cd "$REPO_DIR"
git pull

echo "==> Actualizando archivos del panel"
rsync -av --exclude=config.env deploy/api/package/ "$INSTALL_DIR/"

echo "==> Instalando dependencias (si hay cambios)"
"$INSTALL_DIR/venv/bin/pip" install -r "$INSTALL_DIR/requirements.txt"

echo "==> Reiniciando servicio"
systemctl restart "$SERVICE_NAME"

echo "==> Update completado"
