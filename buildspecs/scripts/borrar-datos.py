# Borrado de los datos de un entorno antes de su destruccion. Lo inyecta destruir-entorno.sh inline
# (python -c) en una tarea one-off con la task definition del servicio <modelo>-<slug>-backend: misma
# imagen y mismas variables que la app (DATABASE_URL, REDIS_URL, CACHE_KEY_PREFIX).
# 1. Confirmacion: DESTROY_CONFIRM tiene que ser el nombre de la base (app_<slug con _>), y la base tiene
#    que ser la de CACHE_KEY_PREFIX. Si no, exit 2 sin tocar nada.
# 2. DROP DATABASE IF EXISTS ... WITH (FORCE) desde la base de mantenimiento (RESET_MAINTENANCE_DB,
#    default postgres) y verificacion de que ya no existe.
# 3. SCAN + DEL de <CACHE_KEY_PREFIX>:* (nunca FLUSHDB: el cluster es compartido) y verificacion de que
#    no quede ninguna.
# Imprime siempre una linea "BORRAR-DATOS {json}". Exit 0 ok, 1 fallo, 2 rechazado.
import json, os, re, sys
import redis
from sqlalchemy import create_engine, make_url, text
from sqlalchemy.pool import NullPool
from app.core.config import settings
r = {"database": None, "db_existia": None, "db_borrada": False, "patron": None, "claves_borradas": 0, "claves_restantes": None, "resultado": "fallo", "motivo": None}
code = 1
try:
    url = make_url(str(settings.DATABASE_URL))
    db = url.database or ""
    pre = settings.CACHE_KEY_PREFIX or ""
    r["database"] = db
    if not (re.fullmatch(r"[a-z0-9-]{1,20}", pre) and db == "app_" + pre.replace("-", "_") and os.environ.get("DESTROY_CONFIRM") == db and settings.REDIS_URL):
        code = 2
        raise RuntimeError("rechazado: DESTROY_CONFIRM, base, CACHE_KEY_PREFIX o REDIS_URL no coinciden")
    r["patron"] = pre + ":*"
    existe = text("SELECT 1 FROM pg_database WHERE datname = :n")
    eng = create_engine(url.set(database=os.environ.get("RESET_MAINTENANCE_DB", "postgres")), isolation_level="AUTOCOMMIT", poolclass=NullPool)
    try:
        with eng.connect() as c:
            r["db_existia"] = c.execute(existe, {"n": db}).first() is not None
            c.execute(text("DROP DATABASE IF EXISTS " + eng.dialect.identifier_preparer.quote_identifier(db) + " WITH (FORCE)"))
            if c.execute(existe, {"n": db}).first() is not None:
                raise RuntimeError("la base sigue existiendo despues del DROP")
            r["db_borrada"] = r["db_existia"]
    finally:
        eng.dispose()
    cl = redis.Redis.from_url(str(settings.REDIS_URL))
    lote = []
    for k in cl.scan_iter(match=r["patron"], count=1000):
        lote.append(k)
        if len(lote) >= 500:
            r["claves_borradas"] += int(cl.delete(*lote))
            lote = []
    if lote:
        r["claves_borradas"] += int(cl.delete(*lote))
    r["claves_restantes"] = sum(1 for _ in cl.scan_iter(match=r["patron"], count=1000))
    if r["claves_restantes"]:
        raise RuntimeError("quedan %d claves %s" % (r["claves_restantes"], r["patron"]))
    r["resultado"], code = "ok", 0
except Exception as e:
    r["motivo"] = ("%s: %s" % (type(e).__name__, e))[:300]
    code = code if code != 0 else 1
print("BORRAR-DATOS " + json.dumps(r, sort_keys=True), flush=True)
sys.exit(code)
