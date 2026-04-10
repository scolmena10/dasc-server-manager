from dotenv import load_dotenv
load_dotenv("config.env")

from urllib.parse import quote
import os
import subprocess
from datetime import datetime

import pymysql
from fastapi import FastAPI, Request, Form
from fastapi.templating import Jinja2Templates
from fastapi.staticfiles import StaticFiles
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import RedirectResponse, JSONResponse

from starlette.middleware.sessions import SessionMiddleware
from starlette.middleware.base import BaseHTTPMiddleware

app = FastAPI()

# =====================
# CONFIG LOGIN / SESIÓN
# =====================
SECRET_KEY = os.getenv("SECRET_KEY", "cambia-esta-clave-por-una-segura")
ADMIN_USER = os.getenv("ADMIN_USER", "admin")
ADMIN_PASSWORD = os.getenv("ADMIN_PASSWORD", "admin123")

templates = Jinja2Templates(directory="templates")
app.mount("/static", StaticFiles(directory="static"), name="static")

# =====================
# CONFIG MULTI-SERVIDOR
# =====================
USUARIO = os.getenv("SSH_USER", "dasc")
SERVIDOR_BACKUPS = os.getenv("BACKUPS_HOST", "192.168.60.30")
SERVIDOR_SERVICIOS = os.getenv("SERVICIOS_HOST", "192.168.60.30")
CACTI_URL = os.getenv("CACTI_URL", "http://127.0.0.1/cacti/")
LOGS_DB_HOST = os.getenv("LOGS_DB_HOST", "192.168.60.20")
LOGS_DB_NAME = os.getenv("LOGS_DB_NAME", "dasc_logs")
LOGS_DB_USER = os.getenv("LOGS_DB_USER", "dasc_logs")
LOGS_DB_PASS = os.getenv("LOGS_DB_PASS", "dascpass")
LOGS_ORIGIN = os.getenv("LOGS_ORIGIN", "dasc-web")

SCRIPT_SERVICIOS = "/usr/local/bin/servicios_api.sh"
SCRIPT_BACKUPS = "/usr/local/bin/backups_api.sh"


def ssh_run(host: str, script: str, args: list[str]) -> str:
    cmd = ["ssh", f"{USUARIO}@{host}", script] + args
    res = subprocess.run(cmd, capture_output=True, text=True)
    out = (res.stdout or "").strip()
    err = (res.stderr or "").strip()

    if res.returncode != 0:
        return f"ERROR ({res.returncode}): {err or out}"

    return out


def log_event(
    tipo: str,
    resultado: str,
    usuario: str | None = "anon",
    ip_origen: str | None = None,
    recurso: str | None = None,
    detalle: str | None = None,
) -> None:
    try:
        conn = pymysql.connect(
            host=LOGS_DB_HOST,
            user=LOGS_DB_USER,
            password=LOGS_DB_PASS,
            database=LOGS_DB_NAME,
            autocommit=True,
            connect_timeout=2,
        )

        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO eventos(origen,tipo,usuario,ip_origen,recurso,resultado,detalle)
                VALUES (%s,%s,%s,%s,%s,%s,%s)
                """,
                (LOGS_ORIGIN, tipo, usuario, ip_origen, recurso, resultado, detalle),
            )

        conn.close()

    except Exception as e:
        print(f"Error guardando evento: {e}")


def is_authenticated(request: Request) -> bool:
    return request.session.get("user") is not None


class AuthAndLogMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        ip = request.client.host if request.client else None
        path = request.url.path
        method = request.method

        public_routes = {"/login"}
        public_prefixes = ("/static", "/favicon.ico")

        is_public = path in public_routes or any(path.startswith(p) for p in public_prefixes)

        if not is_public and not is_authenticated(request):
            log_event(
                tipo="acceso",
                resultado="ERROR",
                usuario="anon",
                ip_origen=ip,
                recurso=f"{method} {path}",
                detalle="Acceso bloqueado por no autenticado",
            )
            return RedirectResponse(url="/login", status_code=303)

        response = await call_next(request)

        usuario = request.session.get("user", "anon")
        status = response.status_code

        if path in ["/", "/servicios", "/backups", "/logs"]:
            tipo = "acceso"
        elif path.startswith("/servicios"):
            tipo = "servicio"
        elif path.startswith("/backups") or path.startswith("/api/backups"):
            tipo = "backup"
        elif path.startswith("/login") or path.startswith("/logout"):
            tipo = "login"
        else:
            tipo = "acceso"

        resultado = "OK" if status < 400 else "ERROR"

        log_event(
            tipo=tipo,
            resultado=resultado,
            usuario=usuario,
            ip_origen=ip,
            recurso=f"{method} {path}",
            detalle=f"HTTP {status}",
        )

        return response


# IMPORTANTE: el orden de alta importa.
# El último add_middleware se ejecuta primero, por eso SessionMiddleware
# debe añadirse después de AuthAndLogMiddleware para que la sesión ya exista
# cuando AuthAndLogMiddleware acceda a request.session.
app.add_middleware(AuthAndLogMiddleware)
app.add_middleware(SessionMiddleware, secret_key=SECRET_KEY)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# =====================
# LOGIN / LOGOUT
# =====================
@app.get("/login")
def login_page(request: Request):
    if is_authenticated(request):
        return RedirectResponse(url="/", status_code=303)

    error = request.query_params.get("error")
    return templates.TemplateResponse(
        request,
        "login.html",
        {
            "error": error,
        },
    )


@app.post("/login")
def login(request: Request, username: str = Form(...), password: str = Form(...)):
    if username == ADMIN_USER and password == ADMIN_PASSWORD:
        request.session["user"] = username
        return RedirectResponse(url="/", status_code=303)

    return RedirectResponse(url="/login?error=1", status_code=303)


@app.get("/logout")
def logout(request: Request):
    request.session.clear()
    return RedirectResponse(url="/login", status_code=303)


# =====================
# RUTAS PRINCIPALES
# =====================
@app.get("/")
def home(request: Request):
    return templates.TemplateResponse(
        request,
        "index.html",
        {
            "user": request.session.get("user"),
        },
    )


@app.get("/backups")
def backups(request: Request):
    ok = request.query_params.get("ok")
    msg = request.query_params.get("msg")

    return templates.TemplateResponse(
        request,
        "backups.html",
        {
            "ok": ok,
            "msg": msg,
            "cacti_url": CACTI_URL,
            "user": request.session.get("user"),
        },
    )


@app.get("/logs")
def ver_logs(request: Request):
    try:
        conn = pymysql.connect(
            host=LOGS_DB_HOST,
            user=LOGS_DB_USER,
            password=LOGS_DB_PASS,
            database=LOGS_DB_NAME,
            autocommit=True,
            connect_timeout=2,
            cursorclass=pymysql.cursors.DictCursor,
        )

        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT id, fecha, origen, tipo, usuario, ip_origen, recurso, resultado, detalle
                FROM eventos
                ORDER BY fecha DESC
                LIMIT 100
                """
            )
            eventos = cur.fetchall()

        conn.close()

    except Exception as e:
        eventos = []
        print(f"Error cargando eventos: {e}")

    return templates.TemplateResponse(
        request,
        "logs.html",
        {
            "cacti_url": CACTI_URL,
            "eventos": eventos,
            "user": request.session.get("user"),
        },
    )


@app.get("/servicios")
def ver_servicios(request: Request):
    salida = ssh_run(SERVIDOR_SERVICIOS, SCRIPT_SERVICIOS, ["list"])
    ok = request.query_params.get("ok")
    msg = request.query_params.get("msg")

    lista_servicios = []
    for linea in salida.split("\n"):
        if "|" in linea:
            nombre, estado = linea.split("|", 1)
            lista_servicios.append({
                "nombre": nombre.strip(),
                "estado": estado.strip(),
            })

    return templates.TemplateResponse(
        request,
        "servicios.html",
        {
            "servicios": lista_servicios,
            "ok": ok,
            "msg": msg,
            "user": request.session.get("user"),
        },
    )


@app.post("/servicios/accion")
def accion_servicio(service: str = Form(...), action: str = Form(...)):
    result = ssh_run(SERVIDOR_SERVICIOS, SCRIPT_SERVICIOS, [action, service])
    ok = 0 if result.startswith("ERROR") else 1
    return RedirectResponse(url=f"/servicios?ok={ok}&msg={quote(result)}", status_code=303)


# =====================
# BACKUPS - ENDPOINTS
# =====================
@app.post("/api/backups/{tipo}")
def ejecutar_backup(tipo: str):
    if tipo not in ["full", "incremental", "differential"]:
        return JSONResponse(
            {"ok": False, "error": "Tipo de backup no válido"},
            status_code=400,
        )

    salida = ssh_run(SERVIDOR_BACKUPS, SCRIPT_BACKUPS, [tipo])
    ok = not salida.startswith("ERROR")

    return {
        "ok": ok,
        "tipo": tipo,
        "resultado": salida,
        "timestamp": datetime.now().isoformat(),
    }


@app.post("/api/test-backups")
def test_backups():
    salida = ssh_run(SERVIDOR_BACKUPS, "/bin/bash", ["-lc", "hostname && date"])
    ok = not salida.startswith("ERROR")

    return {
        "ok": ok,
        "resultado": salida,
    }



def is_ok(output: str) -> bool:
    if not output:
        return False

    o = output.lower()
    return (
        o.startswith("ok")
        or "backup creado" in o
        or "backup completed" in o
        or "success" in o
    )


@app.post("/backups/run")
def backups_run(
    type: str = Form(...),
    db: str = Form(...),
    dest: str = Form("/home/dasc/backups"),
    name: str = Form(...),
    compress: str = Form("gzip"),
    retention: int = Form(7),
    base_ref: str = Form(""),
    notes: str = Form(""),
):
    if type not in ["full", "incremental", "differential"]:
        return RedirectResponse(
            url="/backups?ok=0&msg=Tipo+de+backup+no+valido",
            status_code=303,
        )

    args = [type, db, dest, name, compress, str(retention), base_ref, notes]
    out = ssh_run(SERVIDOR_BACKUPS, SCRIPT_BACKUPS, args)

    ok = 1 if is_ok(out) else 0
    return RedirectResponse(url=f"/backups?ok={ok}&msg={quote(out)}", status_code=303)
