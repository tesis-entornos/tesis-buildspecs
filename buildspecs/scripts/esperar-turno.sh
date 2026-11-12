#!/usr/bin/env bash
# Serialización por entorno del modelo efímero: el build no avanza mientras haya builds de su misma
# rama (mismo entorno), en cualquiera de los PROYECTOS, que arrancaron antes que él.
# Orden: startTime menor; si empatan, build ID menor. Ramas distintas no se esperan entre sí.
#
# La rama de un build ajeno no se puede sacar de la API de CodeBuild (en los de webhook sourceVersion
# es el SHA), así que cada build deja al final de su pre_build, apenas valida, una marca
#   s3://MARCAS_BUCKET/entornos/<slug>/turnos/<build-id>.json   {build_id, rama, slug, start_time}
# (las marcas no se borran: quedan como historia y se van con la destrucción del entorno).
# El estado vivo sale siempre de la API: en cada vuelta se listan los builds de los PROYECTOS
# (paginando, ignorando los de más de 3 h) y se esperan los IN_PROGRESS anteriores al propio que
#   - tienen marca en entornos/<SLUG>/turnos/ (misma rama), o
#   - no tienen marca en ningún entorno todavía (están antes del final de su pre_build): se esperan
#     hasta que aparezca su marca o terminen. Uno que termina sin marca (abortó en la validación)
#     deja de estar IN_PROGRESS y no bloquea; una marca vieja de un build terminado tampoco.
#
# Parámetros (variables): RAMA, SLUG, PROYECTOS (nombres separados por espacios), MARCAS_BUCKET,
# CODEBUILD_BUILD_ID. Opcionales: INTERVALO_SEG (default 15), ESPERA_MAX_SEG (default 3600),
# SALIDA_JSON (archivo donde además se escribe la línea JSON final).
#
# Salida: siempre, también si falla, una línea JSON con resultado (ok | fallo), motivo, espera_seg,
# vueltas, builds_esperados (IDs únicos, en el orden en que se vieron), inicio y fin (UTC con Z).
set -Eeuo pipefail

readonly VENTANA_MS=$((3 * 3600 * 1000))
readonly PAGINA=100

MOTIVO=""
VUELTAS=0
INICIO="$(date -u +%s)"; FIN=""
TMP="$(mktemp -d)"
: > "$TMP/esperados"

iso() { [ -n "$1" ] && jq -nr --argjson e "$1" '$e | todate' || true; }

# startTime (ISO 8601 con fracción y offset, como lo da la CLI v2, o epoch en segundos) a ms epoch.
readonly JQ_MS='
  def ms: if type == "number" then . * 1000 | round
    else capture("^(?<b>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?<f>\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:?[0-9]{2})?$") as $m
      | (($m.z // "Z") | if . == "Z" then 0 else (.[0:1] | if . == "-" then -1 else 1 end) * ((.[1:3] | tonumber) * 3600 + (.[-2:] | tonumber) * 60) end) as $off
      | (($m.b + "Z" | fromdateiso8601) - $off) * 1000 + (("0" + ($m.f // "")) | tonumber * 1000 | round)
    end;'

finalizar() {
  local rc=$1 resultado=ok
  set +e
  [ "$rc" -eq 0 ] || { resultado=fallo; MOTIVO="${MOTIVO:-error inesperado (exit $rc)}"; }
  FIN="$(date -u +%s)"
  RESULTADO="$(jq -nc --arg resultado "$resultado" --arg motivo "$MOTIVO" --argjson vueltas "$VUELTAS" \
    --rawfile esperados "$TMP/esperados" \
    --arg inicio "$(iso "$INICIO")" --arg fin "$(iso "$FIN")" --argjson espera_seg "$((FIN - INICIO))" \
    '{resultado: $resultado, motivo: (if $motivo == "" then null else $motivo end),
      espera_seg: $espera_seg, vueltas: $vueltas,
      builds_esperados: ($esperados | split("\n") | map(select(. != "")) | reduce .[] as $i ([]; if index([$i]) then . else . + [$i] end)),
      inicio: $inicio, fin: $fin}')"
  [ -z "${SALIDA_JSON:-}" ] || echo "$RESULTADO" > "$SALIDA_JSON"
  echo "$RESULTADO"
  rm -rf "$TMP"
  exit "$rc"
}
trap 'finalizar $?' EXIT
trap 'MOTIVO="${MOTIVO:-fallo el comando: $BASH_COMMAND}"' ERR

log() { echo "TURNO - $*"; }
falla() { MOTIVO="$*"; echo "ERROR - $*"; exit 1; }

for v in RAMA SLUG PROYECTOS MARCAS_BUCKET CODEBUILD_BUILD_ID; do
  [ -n "${!v:-}" ] || falla "falta la variable $v"
done
INTERVALO_SEG="${INTERVALO_SEG:-15}"
ESPERA_MAX_SEG="${ESPERA_MAX_SEG:-3600}"
[[ "$INTERVALO_SEG" =~ ^[0-9]+$ && "$ESPERA_MAX_SEG" =~ ^[0-9]+$ ]] \
  || falla "INTERVALO_SEG y ESPERA_MAX_SEG tienen que ser enteros ($INTERVALO_SEG, $ESPERA_MAX_SEG)"
read -r -a LISTA_PROYECTOS <<< "$PROYECTOS"

PROPIO_MS="$(aws codebuild batch-get-builds --ids "$CODEBUILD_BUILD_ID" --output json \
  | jq -r "$JQ_MS"' .builds[0].startTime // empty | ms')" || true
[[ "$PROPIO_MS" =~ ^[0-9]+$ ]] || falla "no se pudo leer el startTime propio de $CODEBUILD_BUILD_ID"
log "build $CODEBUILD_BUILD_ID, rama $RAMA (slug $SLUG), startTime $(iso "$((PROPIO_MS / 1000))"); proyectos ${LISTA_PROYECTOS[*]}"
log "esperando a los builds anteriores de la misma rama (cada ${INTERVALO_SEG} s, timeout ${ESPERA_MAX_SEG} s)"

# Builds de un proyecto, del más nuevo al más viejo, hasta pasar la ventana de 3 h, como jsonl
# {id, estado, fase, ms}.
listar_builds() {
  local proyecto=$1 token="" viejo
  local -a args ids
  while :; do
    args=(--project-name "$proyecto" --sort-order DESCENDING --max-items "$PAGINA")
    [ -z "$token" ] || args+=(--starting-token "$token")
    aws codebuild list-builds-for-project "${args[@]}" --output json > "$TMP/lista.json"
    ids=()
    while IFS= read -r i; do [ -z "$i" ] || ids+=("$i"); done < <(jq -r '.ids[]?' "$TMP/lista.json")
    [ "${#ids[@]}" -gt 0 ] || break
    aws codebuild batch-get-builds --ids "${ids[@]}" --output json \
      | jq -c "$JQ_MS"' .builds[]? | {id, estado: .buildStatus, fase: .currentPhase, ms: (.startTime | ms)}' > "$TMP/pagina.jsonl"
    cat "$TMP/pagina.jsonl" >> "$TMP/builds.jsonl"
    viejo="$(jq -s 'map(.ms) | min // 0' "$TMP/pagina.jsonl")"
    token="$(jq -r '.NextToken // empty' "$TMP/lista.json")"
    [ -n "$token" ] && [ "$viejo" -ge "$LIMITE_MS" ] || break
  done
}

while :; do
  VUELTAS=$((VUELTAS + 1))
  LIMITE_MS=$(( $(date -u +%s) * 1000 - VENTANA_MS ))
  : > "$TMP/builds.jsonl"
  for p in "${LISTA_PROYECTOS[@]}"; do
    listar_builds "$p"
  done
  # Marcas de todos los entornos: build-id -> slug.
  aws s3api list-objects-v2 --bucket "$MARCAS_BUCKET" --prefix entornos/ --output json > "$TMP/marcas.json"
  jq -c '[.Contents[]?.Key | capture("^entornos/(?<slug>[^/]+)/turnos/(?<id>[^/]+)\\.json$")?]
    | map({key: .id, value: .slug}) | from_entries' "$TMP/marcas.json" > "$TMP/marcas-map.json"
  jq -sc --arg propio "$CODEBUILD_BUILD_ID" --argjson pms "$PROPIO_MS" --argjson limite "$LIMITE_MS" \
    --arg slug "$SLUG" --slurpfile marcas "$TMP/marcas-map.json" \
    'map(select(.estado == "IN_PROGRESS" and .id != $propio and .ms >= $limite
                and (.ms < $pms or (.ms == $pms and .id < $propio))))
     | unique_by(.id) | sort_by(.ms, .id)
     | map(. + {marca: $marcas[0][.id]}) | map(select(.marca == null or .marca == $slug))
     | map({id, fase, motivo: (if .marca == null then "sin marca" else "misma rama" end)})' \
    "$TMP/builds.jsonl" > "$TMP/pendientes.json"
  N="$(jq length "$TMP/pendientes.json")"
  if [ "$N" -eq 0 ]; then
    log "vuelta $VUELTAS - no hay builds anteriores de la rama $RAMA en curso; sigue"
    break
  fi
  jq -r '.[].id' "$TMP/pendientes.json" >> "$TMP/esperados"
  log "vuelta $VUELTAS - esperando $N: $(jq -r 'map("\(.id) (\(.motivo), fase \(.fase))") | join(", ")' "$TMP/pendientes.json")"
  if [ $(( $(date -u +%s) - INICIO )) -ge "$ESPERA_MAX_SEG" ]; then
    falla "timeout de serialización: $N builds anteriores de la rama $RAMA siguen en curso después de ${ESPERA_MAX_SEG} s ($(jq -r 'map(.id) | join(", ")' "$TMP/pendientes.json"))"
  fi
  sleep "$INTERVALO_SEG"
done
