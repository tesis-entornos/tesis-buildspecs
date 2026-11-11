#!/usr/bin/env bash
# Corre la suite E2E (imagen tesis-playwright, por digest) contra la URL pública de un entorno
# (mismo script en ambos modelos).
# Parámetros (variables): MODELO, SLUG, SUITE_IMAGEN (<repo>@sha256:<digest>, sin tag),
# FIRST_SUPERUSER_PASSWORD (se pasa al contenedor por nombre, nunca en la línea de comando).
# Opcionales: SALIDA_JSON (archivo donde además se escribe la línea JSON final), RESULTS_JSON
# (ruta donde se deja una copia de results.json para el registro; default /tmp/suite/results.json),
# SUITE_TOTAL_ESPERADO (cantidad de tests que tiene que tener la corrida).
#
# Corrida: docker run --rm --ipc=host con exactamente las variables de abajo y los volúmenes
# test-results, playwright-report y blob-report en un directorio temporal;
# bunx playwright test --grep-invert @requires-email.
# La salida del contenedor pasa por un filtro que reemplaza la contraseña por *** (además del
# enmascarado de CodeBuild para variables de Secrets Manager).
#
# Resultado ok solo si exit_code = 0, unexpected = 0 y (con SUITE_TOTAL_ESPERADO) expected + unexpected
# + flaky + skipped = SUITE_TOTAL_ESPERADO. Si no: "cantidad de tests distinta de la esperada",
# "<n> tests fallidos" o, con exit_code != 0 sin tests fallidos, "error fuera de los tests".
#
# Salida: siempre, también si falla, una línea JSON con suite_imagen, resultado, motivo, exit_code,
# stats, total, total_esperado, flaky[] y fallidos[] (archivo, título y proyecto), errors[] (los
# errors de nivel superior de results.json, resumidos), results_json, inicio, fin (UTC con Z) y suite_seg.
set -Eeuo pipefail

readonly DOMINIO=tesis-entornos.click
readonly FIRST_SUPERUSER=admin@tesis-entornos.click

MOTIVO=""
EXIT_CODE=""
INICIO="$(date -u +%s)"; FIN=""
RESULTS_JSON="${RESULTS_JSON:-/tmp/suite/results.json}"
rm -f "$RESULTS_JSON"
TMP="$(mktemp -d)"

iso() { [ -n "$1" ] && jq -nr --argjson e "$1" '$e | todate' || true; }

# Tests de results.json (reporter json de Playwright) con su ruta de describe, como
# {archivo, titulo, proyecto, estado}. Los suites de primer nivel son los archivos.
readonly JQ_TESTS='
  def specs($ruta):
    (.specs[]? | . as $s | .tests[] | {archivo: $s.file, titulo: (($ruta + [$s.title]) | join(" › ")),
                                       proyecto: .projectName, estado: .status}),
    (.suites[]? | . as $h | specs($ruta + [$h.title]));
  [.suites[]? | specs([])]'

finalizar() {
  local rc=$1 resultado=fallo
  set +e
  FIN="$(date -u +%s)"
  TOTAL=""; ERRORES="[]"
  if [ -s "$RESULTS_JSON" ] && jq -e '.stats' "$RESULTS_JSON" > /dev/null 2>&1; then
    STATS="$(jq -c '.stats | {expected, unexpected, flaky, skipped, duracion_seg: ((.duration // 0) / 1000 | . * 10 | round / 10)}' "$RESULTS_JSON")"
    TESTS="$(jq -c "$JQ_TESTS" "$RESULTS_JSON")"
    TOTAL="$(jq -r '.expected + .unexpected + .flaky + .skipped' <<< "$STATS")"
    UNEXPECTED="$(jq -r '.unexpected' <<< "$STATS")"
    # errors del nivel superior (fuera de los tests), resumidos: los primeros 5, sin colores ANSI,
    # mensaje recortado a 300 caracteres y la contraseña reemplazada por *** (split literal).
    ERRORES="$(jq -c '($ENV.FIRST_SUPERUSER_PASSWORD // "") as $p
      | [(.errors // [])[:5][] | (.message // .value // "" | tostring | gsub("\u001b\\[[0-9;]*m"; "")
          | if $p == "" then . else split($p) | join("***") end) as $m
        | {mensaje: $m[:300], ubicacion: (if .location then "\(.location.file):\(.location.line)" else null end)}]' "$RESULTS_JSON")"
    if [ "$rc" -ne 0 ]; then
      :
    elif [ -n "${SUITE_TOTAL_ESPERADO:-}" ] && [ "$TOTAL" != "$SUITE_TOTAL_ESPERADO" ]; then
      MOTIVO="cantidad de tests distinta de la esperada (esperados $SUITE_TOTAL_ESPERADO, total real $TOTAL)"
    elif [ "$UNEXPECTED" != "0" ]; then
      MOTIVO="$UNEXPECTED tests fallidos"
    elif [ "$EXIT_CODE" != "0" ]; then
      MOTIVO="error fuera de los tests"
    else
      resultado=ok
    fi
  else
    STATS=null; TESTS="[]"
  fi
  [ "$resultado" = "ok" ] || MOTIVO="${MOTIVO:-no hay results.json de la corrida (exit ${EXIT_CODE:-sin exit})}"
  RESULTADO="$(jq -nc --arg suite_imagen "${SUITE_IMAGEN:-}" --arg resultado "$resultado" --arg motivo "$MOTIVO" \
    --arg exit_code "$EXIT_CODE" --argjson stats "$STATS" --argjson tests "$TESTS" \
    --arg total "$TOTAL" --arg total_esperado "${SUITE_TOTAL_ESPERADO:-}" --argjson errors "$ERRORES" \
    --arg results_json "$([ -s "$RESULTS_JSON" ] && echo "$RESULTS_JSON")" \
    --arg inicio "$(iso "$INICIO")" --arg fin "$(iso "$FIN")" --argjson suite_seg "$((FIN - INICIO))" \
    '{suite_imagen: (if $suite_imagen == "" then null else $suite_imagen end), resultado: $resultado,
      motivo: (if $motivo == "" then null else $motivo end),
      exit_code: (if $exit_code == "" then null else ($exit_code | tonumber) end), stats: $stats,
      total: (if $total == "" then null else ($total | tonumber) end),
      total_esperado: (if $total_esperado == "" then null else ($total_esperado | tonumber) end),
      flaky: [$tests[] | select(.estado == "flaky") | {archivo, titulo, proyecto}],
      fallidos: [$tests[] | select(.estado == "unexpected") | {archivo, titulo, proyecto}],
      errors: $errors,
      results_json: (if $results_json == "" then null else $results_json end),
      inicio: $inicio, fin: $fin, suite_seg: $suite_seg}')"
  [ -z "${SALIDA_JSON:-}" ] || echo "$RESULTADO" > "$SALIDA_JSON"
  echo "$RESULTADO"
  rm -rf "$TMP"
  [ "$resultado" = "ok" ] && exit 0
  [ "$rc" -ne 0 ] && exit "$rc"
  exit 1
}
trap 'finalizar $?' EXIT
trap 'MOTIVO="${MOTIVO:-fallo el comando: $BASH_COMMAND}"' ERR

log() { echo "SUITE - $*"; }
falla() { MOTIVO="$*"; echo "ERROR - $*"; exit 1; }

for v in MODELO SLUG SUITE_IMAGEN FIRST_SUPERUSER_PASSWORD; do
  [ -n "${!v:-}" ] || falla "falta la variable $v"
done
[[ "$SUITE_IMAGEN" =~ ^[^@[:space:]]+@sha256:[0-9a-f]{64}$ ]] \
  || falla "SUITE_IMAGEN tiene que venir por digest (<repo>@sha256:<64 hex>): $SUITE_IMAGEN"
REPO="${SUITE_IMAGEN%@*}"
[[ "${REPO##*/}" != *:* ]] || falla "SUITE_IMAGEN no puede traer tag, solo digest: $SUITE_IMAGEN"
REGISTRO="${REPO%%/*}"
[[ "$REGISTRO" =~ ^[0-9]{12}\.dkr\.ecr\.([a-z0-9-]+)\.amazonaws\.com$ ]] || falla "el registro $REGISTRO no es de ECR"
REGION_ECR="${BASH_REMATCH[1]}"
URL="https://${SLUG}.${MODELO}.${DOMINIO}"

log "login a ECR $REGISTRO"
aws ecr get-login-password --region "$REGION_ECR" | docker login --username AWS --password-stdin "$REGISTRO" > /dev/null 2>&1 \
  || falla "no se pudo hacer login a $REGISTRO"
log "pull de $SUITE_IMAGEN"
PULL_INICIO="$(date -u +%s)"
docker pull --quiet "$SUITE_IMAGEN" > /dev/null
log "pull en $(( $(date -u +%s) - PULL_INICIO )) s"

mkdir -p "$TMP/test-results" "$TMP/playwright-report" "$TMP/blob-report" "$(dirname "$RESULTS_JSON")"
log "suite contra $URL (4 workers, 2 retries, --grep-invert @requires-email)"
# FIRST_SUPERUSER_PASSWORD va solo por nombre: docker toma el valor del entorno de este proceso.
# El awk reemplaza la contraseña literal (index, no regex) si llegara a aparecer en la salida.
docker run --rm --ipc=host \
  -e PLAYWRIGHT_BASE_URL="$URL" \
  -e VITE_API_URL="$URL" \
  -e FIRST_SUPERUSER="$FIRST_SUPERUSER" \
  -e FIRST_SUPERUSER_PASSWORD \
  -e PLAYWRIGHT_WORKERS=4 \
  -e PLAYWRIGHT_RETRIES=2 \
  -e PLAYWRIGHT_HTML_HOST=0.0.0.0 \
  -e MAILPIT_HOST=http://mailpit:8025 \
  -e CI= \
  -v "$TMP/test-results:/app/test-results" \
  -v "$TMP/playwright-report:/app/playwright-report" \
  -v "$TMP/blob-report:/app/blob-report" \
  "$SUITE_IMAGEN" bunx playwright test --grep-invert @requires-email 2>&1 \
  | awk 'BEGIN { p = ENVIRON["FIRST_SUPERUSER_PASSWORD"] }
         { if (p != "") while ((i = index($0, p)) > 0) $0 = substr($0, 1, i - 1) "***" substr($0, i + length(p)); print; fflush() }' \
  && EXIT_CODE=0 || EXIT_CODE="${PIPESTATUS[0]}"
log "playwright terminó con exit $EXIT_CODE"

[ -s "$TMP/test-results/results.json" ] || falla "la corrida no dejó test-results/results.json (exit $EXIT_CODE)"
cp "$TMP/test-results/results.json" "$RESULTS_JSON"
log "results.json en $RESULTS_JSON"
# El resultado lo decide finalizar con el results.json y el exit code.
