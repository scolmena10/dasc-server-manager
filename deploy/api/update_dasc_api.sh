#!/usr/bin/env bash
set -e

REPO_DIR="$HOME/dasc-server-manager"
INSTALL_DIR="/opt/dasc/api"
SERVICE_NAME="dasc-api"

echo "==> Actualizando código desde GitHub"
cd "$REPO_DIR"
git pull

echo "==> Actualizando archivos del panel"
cp -r "$REPO_DIR/deploy/api/package/"* "$INSTALL_DIR/"

echo "==> Instalando nuevas dependencias (si hay)"
"$INSTALL_DIR/venv/bin/pip" install -r "$INSTALL_DIR/requirements.txt"

echo "==> Reiniciando servicio"
sudo systemctl restart "$SERVICE_NAME"

echo "==> Update completado"
