# DASC Server Manager

Panel web para la gestión centralizada de servidores, copias de seguridad, servicios y monitorización dentro del MVP del proyecto.

## 1. Descripción del proyecto

DASC Server Manager es un panel web desarrollado con **FastAPI** para administrar un entorno distribuido compuesto por:

- un servidor de **API / panel web**
- un servidor de **backups + gestión de servicios**
- un servidor de **base de datos**
- un sistema de **logs y monitorización**

El objetivo del MVP es demostrar una solución funcional que permita:

- lanzar copias de seguridad desde una interfaz web
- gestionar servicios remotos
- registrar eventos y accesos
- centralizar la operación desde un panel único

---

## 2. Arquitectura del MVP

La arquitectura del proyecto se despliega en **3 máquinas virtuales**:

- **VM 1 - API / Panel web**: `192.168.60.10`
- **VM 2 - Base de datos**: `192.168.60.20`
- **VM 3 - Backups + Servicios**: `192.168.60.30`

Flujo general del sistema:

```text
Usuario / Navegador
        |
        v
API / Panel Web (192.168.60.10)
        |
        | SSH
        v
Backups + Servicios (192.168.60.30)
        |
        | mysqldump
        v
Base de datos MariaDB/MySQL (192.168.60.20)
```

---

## 3. Estructura actual del despliegue

La carpeta `deploy/` del repositorio está organizada por rol.

```text
deploy/
├── api/
├── backup-services/
└── db/
```

### 3.1 `deploy/api`

Contiene el instalador y desinstalador del panel web, junto con el paquete completo de la API.

Estructura recomendada:

```text
deploy/api/
├── install_dasc_api.sh
├── uninstall_dasc_api.sh
└── package/
    ├── main.py
    ├── requirements.txt
    ├── config.env
    ├── templates/
    └── static/
```

### 3.2 `deploy/backup-services`

Contiene el instalador y desinstalador del servidor que ejecuta backups y controla servicios por `systemd`.

Estructura recomendada:

```text
deploy/backup-services/
├── install_backup_services.sh
├── uninstall_backup_services.sh
└── package/
    ├── backups_api.sh
    └── servicios_api.sh
```

### 3.3 `deploy/db`

Contiene el instalador y desinstalador de MariaDB / MySQL del proyecto.

```text
deploy/db/
├── install_db.sh
└── uninstall_db.sh
```

---

## 4. Requisitos previos

### 4.1 Software

- VirtualBox, Isard o entorno equivalente de máquinas virtuales
- Ubuntu Server 22.04 o 24.04
- acceso `sudo` en las 3 VMs
- conectividad de red entre las 3 máquinas
- `git` instalado

### 4.2 Recursos recomendados por VM

- **CPU**: 2 vCPU
- **RAM**: 2 GB mínimo
- **Disco**: 20 GB mínimo
- **Red**: 2 adaptadores recomendados

---

## 5. Configuración de red recomendada

Para laboratorio se recomienda esta configuración en **cada VM**:

- **Adaptador 1: NAT**
  - para instalar paquetes con `apt`
  - para descargar dependencias
  - para clonar el repositorio

- **Adaptador 2: Red interna**
  - nombre recomendado: `dasc-int`
  - para la comunicación entre las tres máquinas

### IPs recomendadas

| VM | Rol | IP |
|---|---|---|
| VM 1 | API / Panel web | `192.168.60.10/24` |
| VM 2 | Base de datos | `192.168.60.20/24` |
| VM 3 | Backups + Servicios | `192.168.60.30/24` |

Antes de tocar la red:

```bash
ip a
```

Aplicar configuración de red y validar:

```bash
ping -c 3 192.168.60.10
ping -c 3 192.168.60.20
ping -c 3 192.168.60.30
```

---

## 6. Orden recomendado de instalación

Instalar siempre en este orden:

1. **Base de datos**
2. **Backups + Servicios**
3. **API / Panel web**

Este orden evita errores porque:

- la máquina de backups necesita que la base ya exista
- la API necesita que el servidor de backups y servicios ya esté preparado

---

## 7. Instalación desde GitHub

En las tres máquinas:

```bash
sudo apt update
sudo apt install -y git
git clone https://github.com/scolmena10/dasc-server-manager.git
```

---

## 8. Instalación de la VM 2 - Base de datos

### Máquina
`192.168.60.20`

### Pasos

```bash
cd ~/dasc-server-manager/deploy/db
chmod +x install_db.sh uninstall_db.sh
sudo ./install_db.sh
```

### Qué debe hacer este instalador

- instalar MariaDB
- dejar el servicio activo
- crear la base de datos de trabajo del MVP
- preparar el acceso del servidor de backups

### Validaciones mínimas

```bash
sudo systemctl status mariadb --no-pager
ss -lntp | grep 3306
sudo mariadb -e "SHOW DATABASES;"
sudo mariadb -e "SELECT User, Host FROM mysql.user;"
```

---

## 9. Instalación de la VM 3 - Backups + Servicios

### Máquina
`192.168.60.30`

### Pasos

```bash
cd ~/dasc-server-manager/deploy/backup-services
chmod +x install_backup_services.sh uninstall_backup_services.sh
sudo ./install_backup_services.sh
```

### Qué debe hacer este instalador

- instalar `openssh-server`
- instalar `mariadb-client`
- crear o reutilizar el usuario `dasc`
- preparar la carpeta `/home/dasc/backups`
- instalar:
  - `/usr/local/bin/backups_api.sh`
  - `/usr/local/bin/servicios_api.sh`
- crear `/home/dasc/.my.cnf`
- preparar permisos para control de servicios

### Validaciones mínimas

```bash
sudo systemctl status ssh --no-pager
ls -l /usr/local/bin/backups_api.sh
ls -l /usr/local/bin/servicios_api.sh
ls -ld /home/dasc/backups
sudo -u dasc test -f /home/dasc/.my.cnf && echo ".my.cnf OK"
sudo -u dasc mysqldump --protocol=tcp --databases employees | head
```

---

## 10. Instalación de la VM 1 - API / Panel web

### Máquina
`192.168.60.10`

### Pasos

```bash
cd ~/dasc-server-manager/deploy/api
chmod +x install_dasc_api.sh uninstall_dasc_api.sh
sudo ./install_dasc_api.sh
```

### Qué debe hacer este instalador

- copiar el proyecto a `/opt/dasc/api`
- crear el entorno virtual `venv`
- instalar dependencias Python
- crear el servicio `dasc-api.service`
- habilitar el arranque automático
- reiniciar el servicio

### Validaciones mínimas

```bash
sudo systemctl status dasc-api --no-pager
ss -lntp | grep 8000
curl -I http://127.0.0.1:8000
```

---

## 11. Configuración del panel

La API usa configuración por variables de entorno mediante `config.env`.

Ruta esperada tras la instalación:

```bash
/opt/dasc/api/config.env
```

Valores típicos del laboratorio:

```env
SSH_USER=dasc

SERVICIOS_HOST=192.168.60.30
BACKUPS_HOST=192.168.60.30

CACTI_URL=/cacti/

LOGS_DB_HOST=192.168.60.20
LOGS_DB_NAME=dasc_logs
LOGS_DB_USER=dasc_logs
LOGS_DB_PASS=dascpass
LOGS_ORIGIN=dasc-web

SECRET_KEY=...
ADMIN_USER=admin
ADMIN_PASSWORD=...
```

Revisar:

```bash
sudo nano /opt/dasc/api/config.env
```

---

## 12. Cómo funciona la aplicación

La API del panel:

- carga configuración desde `config.env`
- sirve plantillas HTML desde `templates/`
- sirve archivos estáticos desde `static/`
- gestiona sesiones y login
- permite usuarios con permisos por módulo
- conecta por SSH con el servidor remoto para:
  - listar servicios
  - arrancar, parar y reiniciar servicios
  - ejecutar backups
- registra eventos en la base de logs

### Módulos funcionales del MVP

#### 12.1 Login y sesión
- login con usuario administrador por variables de entorno
- sesiones basadas en middleware
- logout desde panel

#### 12.2 Usuarios y permisos
- usuarios adicionales desde `data/users.json`
- permisos separados para:
  - `logs`
  - `backups`
  - `servicios`

#### 12.3 Servicios
- listado remoto de servicios vía `servicios_api.sh`
- acciones:
  - `start`
  - `stop`
  - `restart`

#### 12.4 Backups
- formulario de backup desde el panel
- tipos disponibles:
  - `full`
  - `incremental`
  - `differential`
- parámetros:
  - base de datos
  - ruta destino
  - nombre
  - compresión
  - retención
  - referencia base
  - notas

#### 12.5 Logs
- tabla de eventos desde base de datos
- apertura de Cacti desde el panel
- auditoría de acciones del sistema

---

## 13. Acceso al panel

Una vez instalada la API:

```text
http://192.168.60.10:8000
```

Credenciales iniciales:

- usuario: definido por `ADMIN_USER`
- contraseña: definida por `ADMIN_PASSWORD`

---

## 14. Validaciones completas del entorno

### 14.1 Conectividad entre VMs

Desde la API:

```bash
ping -c 3 192.168.60.20
ping -c 3 192.168.60.30
```

### 14.2 SSH desde la API hacia Backups + Servicios

```bash
ssh dasc@192.168.60.30 "hostname && date"
```

### 14.3 Estado del panel

Abrir en navegador:

```text
http://192.168.60.10:8000
```

### 14.4 Prueba de servicios

Desde el panel, entrar en **Servicios** y probar:

- `start`
- `stop`
- `restart`

### 14.5 Prueba de backup

Desde el panel, entrar en **Copias** y lanzar un backup.

Después, comprobar en la VM `192.168.60.30`:

```bash
ls -lah /home/dasc/backups
```

### 14.6 Prueba de logs

Entrar en **Logs** y comprobar:

- apertura de Cacti
- eventos recientes
- estado OK / ERROR de acciones

---

## 15. Rutas importantes del sistema

### VM 1 - API

- instalación:
  ```bash
  /opt/dasc/api
  ```

- servicio:
  ```bash
  /etc/systemd/system/dasc-api.service
  ```

### VM 2 - DB

- servicio:
  ```bash
  mariadb
  ```

### VM 3 - Backups + Servicios

- script de backups:
  ```bash
  /usr/local/bin/backups_api.sh
  ```

- script de servicios:
  ```bash
  /usr/local/bin/servicios_api.sh
  ```

- carpeta de copias:
  ```bash
  /home/dasc/backups
  ```

- credenciales cliente:
  ```bash
  /home/dasc/.my.cnf
  ```

---

## 16. Troubleshooting

### 16.1 La API no arranca

```bash
sudo systemctl status dasc-api --no-pager
sudo journalctl -u dasc-api -n 50 --no-pager
ls -l /opt/dasc/api/venv/bin/uvicorn
```

### 16.2 La API no llega por SSH a la VM de backups

```bash
ssh dasc@192.168.60.30 "hostname"
sudo systemctl status ssh --no-pager
```

### 16.3 El backup falla

En la VM de backups:

```bash
ls -l /usr/local/bin/backups_api.sh
ls -l /home/dasc/.my.cnf
sudo -u dasc mysqldump --protocol=tcp --databases employees | head
```

### 16.4 La DB no acepta conexiones remotas

En la VM de DB:

```bash
sudo systemctl status mariadb --no-pager
ss -lntp | grep 3306
sudo mariadb -e "SELECT User, Host FROM mysql.user;"
```

---

## 17. Desinstalación

### API

```bash
cd ~/dasc-server-manager/deploy/api
sudo ./uninstall_dasc_api.sh
```

### Base de datos

```bash
cd ~/dasc-server-manager/deploy/db
sudo ./uninstall_db.sh
```

### Backups + Servicios

```bash
cd ~/dasc-server-manager/deploy/backup-services
sudo ./uninstall_backup_services.sh
```

---

## 18. Estado funcional del MVP

Actualmente el MVP demuestra:

- login y sesión
- control de accesos por permisos
- ejecución de backups desde web
- gestión remota de servicios
- auditoría de eventos
- integración visual con Cacti
- despliegue por roles dentro de `deploy/`

### Mejoras previstas para versiones posteriores

- restauración desde panel
- historial más avanzado de backups
- backups incrementales y diferenciales reales más allá del flujo MVP
- alertas y notificaciones
- endurecimiento de seguridad
- despliegue todavía más automatizado

---

## 19. Resumen final

Si todo está correcto, el entorno queda así:

- **VM 1 (`192.168.60.10`)**: panel web FastAPI funcionando en el puerto `8000`
- **VM 2 (`192.168.60.20`)**: base de datos lista para recibir `mysqldump`
- **VM 3 (`192.168.60.30`)**: servidor de backups y gestión de servicios accesible por SSH

Con esto queda documentado el **MVP distribuido de DASC Server Manager** con un enfoque de despliegue más limpio, mantenible y alineado con la estructura actual del repositorio.
