#!/usr/bin/env bash
# Despliega una imagen del frontend en un entorno por AWS CLI (mismo script en ambos modelos). Basado
# en tesis-terraform/scripts/publicar-frontend.sh: misma extracción, validaciones, manifiesto,
# frontend_hash y reglas de Cache-Control.
#   a) extraccion: login a ECR del registro de la imagen, pull linux/arm64 y copia de
#      /usr/share/nginx/html; validaciones, manifiesto y frontend_hash
#   b) publicacion: sync sin --delete (no-cache provisorio), cp completo con el Cache-Control de cada
#      grupo, index.html, y al final sync --delete solo para borrar lo que ya no está
#   c) invalidacion: /* en la distribución con el alias del entorno, esperando Completed
#   d) registro: _despliegue.json en la raíz del bucket
# Parámetros (variables): MODELO, SLUG, IMAGEN (<repo>@sha256:<digest>, sin tag).
# Opcionales: SALIDA_JSON (archivo donde además se escribe la línea JSON final), MANIFEST_OUT (copia
# del manifiesto), TIMEOUT_INVALIDACION (segundos, default 900).
# Nombres según tesis-terraform (entorno/): bucket tesis-<modelo>-<slug>-frontend-<cuenta> y alias
# <slug>.<modelo>.tesis-entornos.click. La cuenta sale de sts get-caller-identity.
#
# Cache-Control:
#   assets/ de primer nivel: JS y CSS con hash de Vite → inmutable (se valida que tengan hash).
#   assets/images/: archivos de public/, sin hash en el nombre → no-cache.
#   el resto de la raíz (index.html, 50x.html, ...) → no-cache.
# Solo se conoce assets/images como subcarpeta: otra quedaría sin regla de cache, así que se frena.
#
# Salida: siempre, también si falla, una línea JSON con la etapa alcanzada (extraccion | publicacion |
# invalidacion | registro), el resultado (ok | fallo), el motivo y los tiempos que llegó a medir.
# Funciona en macOS (shasum) y en Linux (sha256sum).
set -Eeuo pipefail

readonly HTML_DIR=/usr/share/nginx/html
readonly PLATFORM=linux/arm64
readonly CACHE_ASSETS="public, max-age=31536000, immutable"
readonly CACHE_OTROS="no-cache"
readonly DOMINIO=tesis-entornos.click
readonly REGISTRO_KEY=_despliegue.json
# Nombre de Vite: <nombre>-<hash de 8>.<ext>
readonly PATRON_HASH='-[A-Za-z0-9_-]{8}\.[A-Za-z0-9]+$'

ETAPA=extraccion
MOTIVO=""
BUCKET=""; DISTRIBUCION=""; INVALIDACION_ID=""; FRONTEND_HASH=""; ARCHIVOS=""; BORRADOS=""
INICIO="$(date -u +%s)"; FIN=""
EXT_INICIO=""; EXT_FIN=""; PUB_INICIO=""; PUB_FIN=""; INV_INICIO=""; INV_FIN=""
CONTAINER=""
TMP="$(mktemp -d "${TMPDIR:-/tmp}/desplegar-frontend.XXXXXX")"

iso() { [ -n "$1" ] && jq -nr --argjson e "$1" '$e | todate' || true; }
dif() { [ -n "$1" ] && [ -n "$2" ] && echo $(( $2 - $1 )) || true; }

# Línea JSON de salida, en éxito o en falla. Lo que no se llegó a medir queda en null.
finalizar() {
  local rc=$1 resultado=ok
  set +e
  [ -z "$CONTAINER" ] || docker rm "$CONTAINER" > /dev/null 2>&1
  [ "$rc" -eq 0 ] || { resultado=fallo; MOTIVO="${MOTIVO:-error inesperado (exit $rc)}"; }
  FIN="$(date -u +%s)"
  RESULTADO="$(jq -nc \
    --arg etapa "$ETAPA" --arg resultado "$resultado" --arg motivo "$MOTIVO" \
    --arg imagen "${IMAGEN:-}" --arg bucket "$BUCKET" --arg distribucion "$DISTRIBUCION" \
    --arg invalidacion_id "$INVALIDACION_ID" --arg frontend_hash "$FRONTEND_HASH" --arg archivos "$ARCHIVOS" --arg borrados "$BORRADOS" \
    --arg inicio "$(iso "$INICIO")" --arg fin "$(iso "$FIN")" \
    --arg extraccion_seg "$(dif "$EXT_INICIO" "$EXT_FIN")" --arg publicacion_seg "$(dif "$PUB_INICIO" "$PUB_FIN")" \
    --arg invalidacion_seg "$(dif "$INV_INICIO" "$INV_FIN")" --arg total_seg "$(dif "$INICIO" "$FIN")" \
    'def s: if . == "" then null else . end; def n: if . == "" then null else tonumber end;
     {etapa: $etapa, resultado: $resultado, motivo: ($motivo | s), imagen: ($imagen | s), bucket: ($bucket | s),
      distribucion: ($distribucion | s), invalidacion_id: ($invalidacion_id | s),
      frontend_hash: ($frontend_hash | s), archivos: ($archivos | n), borrados: ($borrados | n), inicio: $inicio, fin: $fin,
      extraccion_seg: ($extraccion_seg | n), publicacion_seg: ($publicacion_seg | n),
      invalidacion_seg: ($invalidacion_seg | n), total_seg: ($total_seg | n)}')"
  [ -z "${SALIDA_JSON:-}" ] || echo "$RESULTADO" > "$SALIDA_JSON"
  echo "$RESULTADO"
  rm -rf "$TMP"
  exit "$rc"
}
trap 'finalizar $?' EXIT
# Un comando que falla sin pasar por falla() deja el comando como motivo.
trap 'MOTIVO="${MOTIVO:-fallo el comando: $BASH_COMMAND}"' ERR

ahora() { date -u +%s; }
log() { echo "DESPLIEGUE - $*"; }
falla() { MOTIVO="$*"; echo "ERROR - $*"; exit 1; }

for v in MODELO SLUG IMAGEN; do
  [ -n "${!v:-}" ] || falla "falta la variable $v"
done
[[ "$IMAGEN" =~ ^[^@[:space:]]+@sha256:[0-9a-f]{64}$ ]] \
  || falla "IMAGEN tiene que venir por digest (<repo>@sha256:<64 hex>): $IMAGEN"
REPO="${IMAGEN%@*}"
[[ "${REPO##*/}" != *:* ]] || falla "IMAGEN no puede traer tag, solo digest: $IMAGEN"
DIGEST="${IMAGEN#*@}"
REGISTRO="${REPO%%/*}"
[[ "$REGISTRO" =~ ^[0-9]{12}\.dkr\.ecr\.([a-z0-9-]+)\.amazonaws\.com$ ]] || falla "el registro $REGISTRO no es de ECR"
REGION_ECR="${BASH_REMATCH[1]}"
TIMEOUT_INVALIDACION="${TIMEOUT_INVALIDACION:-900}"

for cmd in docker aws jq; do
  command -v "$cmd" > /dev/null 2>&1 || falla "falta el comando $cmd"
done
if command -v sha256sum > /dev/null 2>&1; then
  sha256() { sha256sum "$@"; }
elif command -v shasum > /dev/null 2>&1; then
  sha256() { shasum -a 256 "$@"; }
else
  falla "falta sha256sum o shasum"
fi

CUENTA="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="tesis-${MODELO}-${SLUG}-frontend-${CUENTA}"
ALIAS="${SLUG}.${MODELO}.${DOMINIO}"
log "bucket $BUCKET, alias $ALIAS, imagen $IMAGEN"

# --- a) Extracción --------------------------------------------------------------

EXT_INICIO="$(ahora)"
log "login a ECR $REGISTRO"
aws ecr get-login-password --region "$REGION_ECR" | docker login --username AWS --password-stdin "$REGISTRO" > /dev/null 2>&1 \
  || falla "no se pudo hacer login a $REGISTRO"
log "pull de $IMAGEN ($PLATFORM)"
docker pull --quiet --platform "$PLATFORM" "$IMAGEN" > /dev/null

CONTAINER="$(docker create --platform "$PLATFORM" "$IMAGEN")"
docker cp "$CONTAINER:$HTML_DIR" "$TMP/html"
docker rm "$CONTAINER" > /dev/null
CONTAINER=""

SITE="$TMP/html"
[ -f "$SITE/index.html" ] || falla "la imagen no tiene $HTML_DIR/index.html"
[ -d "$SITE/assets" ] || falla "la imagen no tiene $HTML_DIR/assets"
[ ! -e "$SITE/$REGISTRO_KEY" ] || falla "la imagen trae $REGISTRO_KEY, que es el registro del despliegue"
OTRAS="$(cd "$SITE/assets" && find . -mindepth 1 -type d ! -path './images' ! -path './images/*')"
[ -z "$OTRAS" ] || falla "subcarpetas de assets/ sin regla de cache: $(echo "$OTRAS" | tr '\n' ' ')"
# Inmutable solo es seguro si el nombre cambia con el contenido.
SIN_HASH="$(cd "$SITE/assets" && find . -maxdepth 1 -type f | sed 's|^\./||' | { grep -Ev -- "$PATRON_HASH" || true; })"
[ -z "$SIN_HASH" ] || falla "archivos de primer nivel de assets/ sin hash en el nombre: $(echo "$SIN_HASH" | tr '\n' ' ')"

# Manifiesto "<sha256>  <ruta relativa>", ordenado por ruta (orden de bytes, igual en macOS y Linux).
# El hash del frontend es el sha256 del manifiesto.
MANIFEST="$TMP/manifest.txt"
(
  cd "$SITE"
  find . -type f | sed 's|^\./||' | LC_ALL=C sort | while IFS= read -r path; do
    printf '%s  %s\n' "$(sha256 "$path" | cut -d' ' -f1)" "$path"
  done
) > "$MANIFEST"
ARCHIVOS="$(wc -l < "$MANIFEST" | tr -d ' ')"
[ "$ARCHIVOS" -gt 0 ] || falla "no hay archivos para publicar"
FRONTEND_HASH="$(sha256 "$MANIFEST" | cut -d' ' -f1)"
[ -z "${MANIFEST_OUT:-}" ] || cp "$MANIFEST" "$MANIFEST_OUT"
EXT_FIN="$(ahora)"
log "$ARCHIVOS archivos, frontend_hash $FRONTEND_HASH ($((EXT_FIN - EXT_INICIO)) s)"

# --- b) Publicación -------------------------------------------------------------

ETAPA=publicacion
PUB_INICIO="$(ahora)"
# El borrado va al final: mientras se sube, el index.html viejo sigue encontrando sus assets.
# 1. sync sin --delete: sube lo nuevo con no-cache provisorio (el paso 2 pone el definitivo).
#    index.html queda para el paso 3 y _despliegue.json no se toca.
log "1/4 sync sin --delete → s3://$BUCKET (sin index.html ni $REGISTRO_KEY, $CACHE_OTROS provisorio)"
aws s3 sync "$SITE" "s3://$BUCKET" --exclude "$REGISTRO_KEY" --exclude "index.html" \
  --no-progress --only-show-errors --cache-control "$CACHE_OTROS"
# 2. cp completo: sobrescribe todo con su Cache-Control (sync no vuelve a subir un archivo de igual
#    tamaño si el local es más viejo, y docker cp conserva la fecha de la imagen).
log "2/4 cp assets/ de primer nivel ($CACHE_ASSETS)"
aws s3 cp "$SITE/assets" "s3://$BUCKET/assets" --recursive --exclude "*/*" \
  --no-progress --only-show-errors --cache-control "$CACHE_ASSETS"
if [ -d "$SITE/assets/images" ]; then
  log "2/4 cp assets/images/ ($CACHE_OTROS)"
  aws s3 cp "$SITE/assets/images" "s3://$BUCKET/assets/images" --recursive \
    --no-progress --only-show-errors --cache-control "$CACHE_OTROS"
fi
log "2/4 cp resto de la raíz sin index.html ($CACHE_OTROS)"
aws s3 cp "$SITE" "s3://$BUCKET" --recursive --exclude "assets/*" --exclude "index.html" \
  --no-progress --only-show-errors --cache-control "$CACHE_OTROS"
# 3. index.html, cuando todo lo que referencia ya está.
log "3/4 index.html ($CACHE_OTROS)"
aws s3 cp "$SITE/index.html" "s3://$BUCKET/index.html" \
  --no-progress --only-show-errors --cache-control "$CACHE_OTROS"
# 4. sync --delete solo para borrar lo que ya no está (con --size-only no vuelve a subir nada: todo
#    se acaba de copiar). Se cuentan los "delete:" de la salida.
log "4/4 sync --delete (sin index.html ni $REGISTRO_KEY), solo para borrar lo que ya no está"
SALIDA_SYNC="$(aws s3 sync "$SITE" "s3://$BUCKET" --delete --size-only --exclude "$REGISTRO_KEY" --exclude "index.html" --no-progress)"
[ -z "$SALIDA_SYNC" ] || echo "$SALIDA_SYNC"
BORRADOS="$(grep -c '^delete: ' <<< "$SALIDA_SYNC" || true)"
SUBIDOS_EN_BORRADO="$(grep -c '^upload: ' <<< "$SALIDA_SYNC" || true)"
[ "$SUBIDOS_EN_BORRADO" -eq 0 ] || log "aviso: el sync de borrado subió $SUBIDOS_EN_BORRADO archivos"
PUB_FIN="$(ahora)"
log "publicado en $((PUB_FIN - PUB_INICIO)) s, $BORRADOS objetos borrados"

# --- c) Invalidación ------------------------------------------------------------

ETAPA=invalidacion
INV_INICIO="$(ahora)"
DISTS="$(aws cloudfront list-distributions --output json \
  | jq -c --arg a "$ALIAS" '[.DistributionList.Items[]? | select((.Aliases.Items // []) | index($a)) | .Id]')"
[ "$(jq 'length' <<< "$DISTS")" -eq 1 ] || falla "se esperaba exactamente una distribución con el alias $ALIAS y hay $DISTS"
DISTRIBUCION="$(jq -r '.[0]' <<< "$DISTS")"
INVALIDACION_ID="$(aws cloudfront create-invalidation --distribution-id "$DISTRIBUCION" --paths '/*' \
  --query Invalidation.Id --output text)"
log "invalidación $INVALIDACION_ID de /* en $DISTRIBUCION, esperando Completed (timeout ${TIMEOUT_INVALIDACION} s)"
while :; do
  ESTADO="$(aws cloudfront get-invalidation --distribution-id "$DISTRIBUCION" --id "$INVALIDACION_ID" \
    --query Invalidation.Status --output text)"
  [ "$ESTADO" != "Completed" ] || break
  if [ $(( $(ahora) - INV_INICIO )) -ge "$TIMEOUT_INVALIDACION" ]; then
    INV_FIN="$(ahora)"
    falla "la invalidación $INVALIDACION_ID no completó en ${TIMEOUT_INVALIDACION} s (estado $ESTADO)"
  fi
  sleep 5
done
INV_FIN="$(ahora)"
log "invalidación Completed en $((INV_FIN - INV_INICIO)) s"

# --- d) Registro ----------------------------------------------------------------

ETAPA=registro
jq -n --arg imagen "$IMAGEN" --arg digest "$DIGEST" --arg frontend_hash "$FRONTEND_HASH" \
  --argjson archivos "$ARCHIVOS" --arg publicado_at "$(iso "$(ahora)")" \
  '{imagen: $imagen, digest: $digest, frontend_hash: $frontend_hash, archivos: $archivos, publicado_at: $publicado_at}' \
  > "$TMP/$REGISTRO_KEY"
aws s3 cp "$TMP/$REGISTRO_KEY" "s3://$BUCKET/$REGISTRO_KEY" --no-progress --only-show-errors \
  --content-type application/json --cache-control "$CACHE_OTROS"
log "registro s3://$BUCKET/$REGISTRO_KEY"
