# DASC Server Manager - Manual de instalacion en maquinas virtuales

## 1. Objetivo

Este documento describe la instalacion del **MVP de DASC Server Manager** en un entorno de **maquinas virtuales**.

La arquitectura se despliega en **3 VMs separadas**:

- **VM 1 - API / Panel web**: `192.168.60.10`
- **VM 2 - Base de datos**: `192.168.60.20`
- **VM 3 - Backups + Servicios**: `192.168.60.30`

Flujo general del sistema:

```text
Usuario/Navegador
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

## 2. Requisitos previos

### 2.1 Software

- VirtualBox, Isard o entorno equivalente de VMs
- Ubuntu Server 24.04 o similar en las 3 maquinas
- Acceso `sudo` en las 3 VMs
- Paquetes del proyecto:
  - `install_dasc_api.sh`
  - `uninstall_dasc_api.sh`
  - `install_db.sh`
  - `uninstall_db.sh`
  - `install_backup_services.sh`
  - `uninstall_backup_services.sh`

### 2.2 Recursos recomendados por VM

- **CPU**: 2 vCPU
- **RAM**: 2 GB minimo
- **Disco**: 20 GB minimo
- **Red**: 2 adaptadores recomendados

---

## 3. Configuracion de red recomendada

### 3.1 Adaptadores

Para trabajar comodamente en laboratorio se recomienda esta configuracion en **cada VM**:

- **Adaptador 1: NAT**
  - Se usa para instalar paquetes con `apt`, actualizar el sistema y tener salida a Internet.
- **Adaptador 2: Red interna**
  - Nombre recomendado: `dasc-int`
  - Se usa para la comunicacion entre las 3 VMs.

### 3.2 IPs fijas

Asignar estas IPs en el **adaptador interno**:

| VM | Rol | IP |
|---|---|---|
| VM 1 | API / Panel web | `192.168.60.10/24` |
| VM 2 | Base de datos | `192.168.60.20/24` |
| VM 3 | Backups + Servicios | `192.168.60.30/24` |

### 3.3 Comprobar interfaces

Antes de tocar `netplan`, comprobar el nombre real de las interfaces:

```bash
ip a
```

Lo habitual es:

- `enp0s3` -> NAT
- `enp0s8` -> Red interna

Puede variar segun la VM.

### 3.4 Configurar IP estatica

Editar:

```bash
sudo nano /etc/netplan/00-installer-config.yaml
```

#### VM 1 - API (`192.168.60.10`)

```yaml
network:
  version: 2
  ethernets:
    enp0s3:
      dhcp4: true
    enp0s8:
      dhcp4: false
      addresses:
        - 192.168.60.10/24
```

#### VM 2 - DB (`192.168.60.20`)

```yaml
network:
  version: 2
  ethernets:
    enp0s3:
      dhcp4: true
    enp0s8:
      dhcp4: false
      addresses:
        - 192.168.60.20/24
```

#### VM 3 - Backups + Servicios (`192.168.60.30`)

```yaml
network:
  version: 2
  ethernets:
    enp0s3:
      dhcp4: true
    enp0s8:
      dhcp4: false
      addresses:
        - 192.168.60.30/24
```

Aplicar cambios:

```bash
sudo netplan apply
```

Validar:

```bash
ip a
ping -c 3 192.168.60.10
ping -c 3 192.168.60.20
ping -c 3 192.168.60.30
```

---

## 4. Orden recomendado de instalacion

Instalar en este orden:

1. **Base de datos** (`192.168.60.20`)
2. **Backups + Servicios** (`192.168.60.30`)
3. **API / Panel web** (`192.168.60.10`)

Este orden evita errores porque:

- el servidor de backups necesita que la base de datos ya exista;
- la API necesita que el servidor de backups y servicios ya este preparado.

---

## 5. Instalacion de la VM 2 - Base de datos

### 5.1 Copiar el paquete de instalacion

Copiar a la VM de base de datos el paquete correspondiente, por ejemplo:

```bash
scp install_db.sh uninstall_db.sh usuario@192.168.60.20:/home/usuario/
```

### 5.2 Ejecutar el instalador

Dentro de la VM `192.168.60.20`:

```bash
chmod +x install_db.sh uninstall_db.sh
sudo ./install_db.sh
```

### 5.3 Validaciones minimas

Comprobar que el servicio de base de datos esta levantado:

```bash
sudo systemctl status mariadb --no-pager
```

Comprobar escucha en el puerto 3306:

```bash
ss -lntp | grep 3306
```

Si el instalador crea el usuario de backup, comprobarlo desde MariaDB:

```bash
sudo mariadb
SELECT User, Host FROM mysql.user;
```

Salir:

```sql
exit;
```

---

## 6. Instalacion de la VM 3 - Backups + Servicios

### 6.1 Copiar el paquete de instalacion

Copiar a la VM `192.168.60.30`:

```bash
scp install_backup_services.sh uninstall_backup_services.sh backups_api.sh servicios_api.sh usuario@192.168.60.30:/home/usuario/
```

### 6.2 Ejecutar el instalador

Dentro de la VM `192.168.60.30`:

```bash
chmod +x install_backup_services.sh uninstall_backup_services.sh
sudo ./install_backup_services.sh
```

### 6.3 Comprobar SSH

```bash
sudo systemctl status ssh --no-pager
```

### 6.4 Comprobar scripts instalados

```bash
ls -l /usr/local/bin/backups_api.sh
ls -l /usr/local/bin/servicios_api.sh
```

### 6.5 Comprobar carpeta de backups

```bash
ls -ld /home/dasc/backups
```

### 6.6 Comprobar acceso a la base de datos desde la VM de backups

Si el instalador ha creado correctamente `/home/dasc/.my.cnf`, se puede probar:

```bash
sudo -u dasc mysqldump --protocol=tcp --databases employees | head
```

Si esa prueba funciona, la maquina de backups ya puede sacar copias de la VM de base de datos.

---

## 7. Instalacion de la VM 1 - API / Panel web

### 7.1 Copiar el paquete de instalacion

Copiar a la VM `192.168.60.10`:

```bash
scp -r install_dasc_api.sh uninstall_dasc_api.sh main.py requirements.txt config.env templates static usuario@192.168.60.10:/home/usuario/dasc-api/
```

### 7.2 Ejecutar el instalador

Dentro de la VM `192.168.60.10`:

```bash
cd /home/usuario/dasc-api
chmod +x install_dasc_api.sh uninstall_dasc_api.sh
sudo ./install_dasc_api.sh
```

### 7.3 Revisar configuracion

El instalador copia el proyecto a:

```bash
/opt/dasc/api
```

Revisar el fichero:

```bash
sudo nano /opt/dasc/api/config.env
```

Contenido esperado:

```env
SSH_USER=dasc
SERVICIOS_HOST=192.168.60.30
BACKUPS_HOST=192.168.60.30
CACTI_URL=/cacti/
```

### 7.4 Comprobar servicio

```bash
sudo systemctl status dasc-api --no-pager
```

### 7.5 Comprobar que escucha en el puerto 8000

```bash
ss -lntp | grep 8000
```

### 7.6 Comprobar acceso local

```bash
curl -I http://127.0.0.1:8000
```

---

## 8. Validaciones completas del entorno

### 8.1 Conectividad entre VMs

Desde la API (`192.168.60.10`):

```bash
ping -c 3 192.168.60.20
ping -c 3 192.168.60.30
```

### 8.2 SSH desde la API hacia Backups + Servicios

```bash
ssh dasc@192.168.60.30 "hostname && date"
```

### 8.3 Estado del panel

Abrir en navegador:

```text
http://192.168.60.10:8000
```

### 8.4 Prueba de servicios

Desde el panel, entrar en **Servicios** y probar:
- `start`
- `stop`
- `restart`

### 8.5 Prueba de backup

Desde el panel, entrar en **Copias** y lanzar un backup.

Despues, comprobar en la VM `192.168.60.30`:

```bash
ls -lah /home/dasc/backups
```

---

## 9. Rutas importantes del sistema

### VM 1 - API

- Proyecto instalado:
  ```bash
  /opt/dasc/api
  ```
- Servicio:
  ```bash
  /etc/systemd/system/dasc-api.service
  ```

### VM 2 - DB

- Servicio MariaDB:
  ```bash
  mariadb
  ```

### VM 3 - Backups + Servicios

- Script de backups:
  ```bash
  /usr/local/bin/backups_api.sh
  ```
- Script de servicios:
  ```bash
  /usr/local/bin/servicios_api.sh
  ```
- Carpeta de copias:
  ```bash
  /home/dasc/backups
  ```
- Credenciales de cliente:
  ```bash
  /home/dasc/.my.cnf
  ```

---

## 10. Comandos de soporte y troubleshooting

### 10.1 API no arranca

```bash
sudo systemctl status dasc-api --no-pager
sudo journalctl -u dasc-api -n 50 --no-pager
ls -l /opt/dasc/api/venv/bin/uvicorn
```

### 10.2 La API no llega por SSH a la VM de backups

```bash
ssh dasc@192.168.60.30 "hostname"
sudo systemctl status ssh --no-pager
```

### 10.3 El backup falla

Comprobar en la VM de backups:

```bash
ls -l /usr/local/bin/backups_api.sh
ls -l /home/dasc/.my.cnf
sudo -u dasc mysqldump --protocol=tcp --databases employees | head
```

### 10.4 La DB no acepta conexiones remotas

En la VM de DB:

```bash
sudo systemctl status mariadb --no-pager
ss -lntp | grep 3306
sudo mariadb -e "SELECT User, Host FROM mysql.user;"
```

---

## 11. Desinstalacion

### 11.1 API

En `192.168.60.10`:

```bash
sudo ./uninstall_dasc_api.sh
```

### 11.2 Base de datos

En `192.168.60.20`:

```bash
sudo ./uninstall_db.sh
```

### 11.3 Backups + Servicios

En `192.168.60.30`:

```bash
sudo ./uninstall_backup_services.sh
```

---

## 12. Resumen final

Si todo esta correcto, el entorno queda asi:

- **VM 1 (`192.168.60.10`)**: panel web FastAPI funcionando en el puerto `8000`
- **VM 2 (`192.168.60.20`)**: base de datos lista para recibir `mysqldump`
- **VM 3 (`192.168.60.30`)**: servidor de backups y gestion de servicios accesible por SSH

Con esto queda instalado el MVP distribuido de DASC Server Manager en entorno de laboratorio con maquinas virtuales.
