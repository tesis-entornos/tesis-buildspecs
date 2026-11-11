#!/usr/bin/env bash
# Espera a que un entorno responda por su URL pública (mismo script en ambos modelos).
#   https://<slug>.<modelo>.tesis-entornos.click/          (frontend, por CloudFront)
#   https://<slug>.<modelo>.tesis-entornos.click/api/v1/utils/ready   (backend, por la misma URL)
# Un sondeo es ok si las dos dan 200. Termina bien con 3 sondeos ok seguidos (no corta en el primer
# 200: después de un despliegue puede haber respuestas alternadas). Sondeo cada 5 s, timeout 10 min.
# Parámetros (variables): MODELO, SLUG.
# Opcionales: SALIDA_JSON (archivo donde además se escribe la línea JSON final), TIMEOUT_ESPERA
# (segundos, default 600), INTERVALO (segundos, default 5), OK_SEGUIDOS (default 3).
#
# Salida: siempre, también si falla, una línea JSON con resultado (ok | fallo), motivo, sondeos,
# sondeos_fallidos y, por cada URL que falló, curl_exit, código HTTP e IP resuelta (los últimos 50),
# inicio, fin (UTC con Z) y espera_seg.
set -Eeuo pipefail

readonly DOMINIO=tesis-entornos.click
readonly MAX_FALLIDOS_JSON=50

MOTIVO=""
SONDEOS=0
FALLIDOS_TOTAL=0
INICIO="$(date -u +%s)"; FIN=""
URL_BASE=""
TMP="$(mktemp -d)"
: > "$TMP/fallidos.jsonl"

iso() { [ -n "$1" ] && jq -nr --argjson e "$1" '$e | todate' || true; }

finalizar() {
  local rc=$1 resultado=ok
  set +e
  [ "$rc" -eq 0 ] || { resultado=fallo; MOTIVO="${MOTIVO:-error inesperado (exit $rc)}"; }
  FIN="$(date -u +%s)"
  RESULTADO="$(jq -nc --arg resultado "$resultado" --arg motivo "$MOTIVO" --arg url "$URL_BASE" \
    --argjson sondeos "$SONDEOS" --argjson fallidos_total "$FALLIDOS_TOTAL" \
    --slurpfile fallidos "$TMP/fallidos.jsonl" --argjson max "$MAX_FALLIDOS_JSON" \
    --arg inicio "$(iso "$INICIO")" --arg fin "$(iso "$FIN")" --argjson espera_seg "$((FIN - INICIO))" \
    '{resultado: $resultado, motivo: (if $motivo == "" then null else $motivo end),
      url: (if $url == "" then null else $url end), sondeos: $sondeos,
      sondeos_fallidos: $fallidos_total, fallidos: $fallidos[-$max:],
      inicio: $inicio, fin: $fin, espera_seg: $espera_seg}')"
  [ -z "${SALIDA_JSON:-}" ] || echo "$RESULTADO" > "$SALIDA_JSON"
  echo "$RESULTADO"
  rm -rf "$TMP"
  exit "$rc"
}
trap 'finalizar $?' EXIT
trap 'MOTIVO="${MOTIVO:-fallo el comando: $BASH_COMMAND}"' ERR

log() { echo "ESPERA - $*"; }
falla() { MOTIVO="$*"; echo "ERROR - $*"; exit 1; }

for v in MODELO SLUG; do
  [ -n "${!v:-}" ] || falla "falta la variable $v"
done
TIMEOUT_ESPERA="${TIMEOUT_ESPERA:-600}"
INTERVALO="${INTERVALO:-5}"
OK_SEGUIDOS="${OK_SEGUIDOS:-3}"

HOST="${SLUG}.${MODELO}.${DOMINIO}"
URL_BASE="https://${HOST}"
URLS=("$URL_BASE/" "$URL_BASE/api/v1/utils/ready")
log "esperando $OK_SEGUIDOS sondeos ok seguidos de ${URLS[*]} (cada ${INTERVALO} s, timeout ${TIMEOUT_ESPERA} s)"

# Sondea una URL: imprime "<curl_exit> <http> <ip>" (http 000 e ip vacía si no hubo respuesta).
sondear() {
  local salida rc=0
  salida="$(curl -s -o /dev/null --max-time 10 -w '%{http_code} %{remote_ip}' "$1")" || rc=$?
  echo "$rc $salida"
}

SEGUIDOS=0
while :; do
  SONDEOS=$((SONDEOS + 1))
  AHORA="$(date -u +%s)"
  OK=1
  for u in "${URLS[@]}"; do
    read -r CURL_EXIT HTTP IP <<< "$(sondear "$u")"
    if [ "$CURL_EXIT" != "0" ] || [ "$HTTP" != "200" ]; then
      OK=0
      # Sin respuesta no hay remote_ip: se resuelve aparte para registrar a dónde apunta el nombre.
      [ -n "${IP:-}" ] || IP="$(getent ahosts "$HOST" 2> /dev/null | awk 'NR == 1 {print $1}' || true)"
      jq -nc --argjson sondeo "$SONDEOS" --arg at "$(iso "$AHORA")" --arg url "$u" \
        --argjson curl_exit "$CURL_EXIT" --arg http "${HTTP:-000}" --arg ip "${IP:-}" \
        '{sondeo: $sondeo, at: $at, url: $url, curl_exit: $curl_exit, http: $http, ip: (if $ip == "" then null else $ip end)}' \
        >> "$TMP/fallidos.jsonl"
      log "sondeo $SONDEOS fallido: $u curl_exit=$CURL_EXIT http=${HTTP:-000} ip=${IP:--}"
    fi
  done
  if [ "$OK" = "1" ]; then
    SEGUIDOS=$((SEGUIDOS + 1))
    log "sondeo $SONDEOS ok ($SEGUIDOS/$OK_SEGUIDOS seguidos)"
    [ "$SEGUIDOS" -lt "$OK_SEGUIDOS" ] || break
  else
    SEGUIDOS=0
    FALLIDOS_TOTAL=$((FALLIDOS_TOTAL + 1))
  fi
  if [ $(( $(date -u +%s) - INICIO )) -ge "$TIMEOUT_ESPERA" ]; then
    falla "el entorno no respondió $OK_SEGUIDOS sondeos ok seguidos en ${TIMEOUT_ESPERA} s ($SONDEOS sondeos, $FALLIDOS_TOTAL fallidos)"
  fi
  sleep "$INTERVALO"
done
log "entorno ok: $SEGUIDOS sondeos seguidos con 200 en las dos URLs"
