#!/usr/bin/env bash
# Despliega una imagen del backend en un entorno por AWS CLI (mismo script en ambos modelos):
#   a) task definition nueva: la actual del servicio con la imagen reemplazada en el contenedor backend
#   b) migraciones: tarea one-off con esa task definition (scripts/prestart.sh)
#   c) update-service con la task definition nueva, esperando el rollout
# Parámetros (variables): MODELO, SLUG, IMAGEN (<repo>@sha256:<digest>).
# Opcionales: STARTED_BY (default: UUID del build de CodeBuild), SALIDA_JSON (archivo donde además
# se escribe la línea JSON final), TIMEOUT_UPDATE (segundos, default 900).
# Nombres según tesis-terraform (base-modelo/ y entorno/): cluster <modelo>-cluster, servicio y
# familia <modelo>-<slug>-backend, log group /ecs/<modelo>, streams <slug>/backend/<id de tarea>.
#
# Salida: siempre, también si falla, una línea JSON con la etapa alcanzada (task_definition |
# migracion | update), el resultado (ok | fallo), el motivo y los tiempos que llegó a medir.
#
# Limitación: se copia la task definition que corre el servicio, no la de Terraform (el servicio
# tiene ignore_changes en task_definition). Un cambio de configuración del contenedor en Terraform
# (variables, secretos, cpu/memoria, roles, logs) registra una revisión que el servicio no usa y que
# este script no toma: no se propaga solo hasta que el servicio pase a esa revisión.
set -Eeuo pipefail

ETAPA=task_definition
MOTIVO=""
TD_ANTERIOR=""; TD_NUEVA=""; TAREA_ID=""; MIG_EXIT=""
MIG_INICIO=""; MIG_FIN=""; UPD_INICIO=""; UPD_FIN=""
TMP="$(mktemp -d)"

iso() { [ -n "$1" ] && jq -nr --argjson e "$1" '$e | todate' || true; }
dif() { [ -n "$1" ] && [ -n "$2" ] && echo $(( $2 - $1 )) || true; }

# Línea JSON de salida, en éxito o en falla. Los campos que no se llegaron a medir quedan en null.
finalizar() {
  local rc=$1 resultado=ok fin
  set +e
  [ "$rc" -eq 0 ] || { resultado=fallo; MOTIVO="${MOTIVO:-error inesperado (exit $rc)}"; }
  fin="${UPD_FIN:-${MIG_FIN:-}}"
  RESULTADO="$(jq -nc \
    --arg etapa "$ETAPA" --arg resultado "$resultado" --arg motivo "$MOTIVO" \
    --arg task_definition "$TD_NUEVA" --arg task_definition_anterior "$TD_ANTERIOR" --arg imagen "${IMAGEN:-}" \
    --arg migracion_tarea "$TAREA_ID" --arg migracion_inicio "$(iso "$MIG_INICIO")" --arg migracion_fin "$(iso "$MIG_FIN")" \
    --arg migracion_exit "$MIG_EXIT" --arg migracion_seg "$(dif "$MIG_INICIO" "$MIG_FIN")" \
    --arg update_inicio "$(iso "$UPD_INICIO")" --arg update_fin "$(iso "$UPD_FIN")" \
    --arg update_seg "$(dif "$UPD_INICIO" "$UPD_FIN")" --arg total_seg "$(dif "$MIG_INICIO" "$fin")" \
    'def s: if . == "" then null else . end; def n: if . == "" then null else tonumber end;
     {etapa: $etapa, resultado: $resultado, motivo: ($motivo | s),
      task_definition: ($task_definition | s), task_definition_anterior: ($task_definition_anterior | s), imagen: ($imagen | s),
      migracion_tarea: ($migracion_tarea | s), migracion_inicio: ($migracion_inicio | s), migracion_fin: ($migracion_fin | s),
      migracion_exit: ($migracion_exit | n), migracion_seg: ($migracion_seg | n),
      update_inicio: ($update_inicio | s), update_fin: ($update_fin | s), update_seg: ($update_seg | n),
      total_seg: ($total_seg | n)}')"
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
[[ "$IMAGEN" =~ ^[^@]+@sha256:[0-9a-f]{64}$ ]] || falla "IMAGEN tiene que ser <repo>@sha256:<64 hex> ($IMAGEN)"

CONTENEDOR=backend
CLUSTER="${MODELO}-cluster"
SERVICIO="${MODELO}-${SLUG}-backend"
FAMILIA="$SERVICIO"
LOG_GROUP="/ecs/${MODELO}"
LOG_PREFIX="${SLUG}/${CONTENEDOR}"
TIMEOUT_UPDATE="${TIMEOUT_UPDATE:-900}"
# startedBy admite hasta 36 letras, números, guiones y guiones bajos: del build id queda el UUID.
STARTED_BY="${STARTED_BY:-${CODEBUILD_BUILD_ID:-manual}}"
STARTED_BY="${STARTED_BY##*:}"
STARTED_BY="${STARTED_BY//[^A-Za-z0-9_-]/-}"
STARTED_BY="${STARTED_BY:0:36}"

log "cluster $CLUSTER, servicio $SERVICIO, imagen $IMAGEN"

# --- a) Task definition nueva ---------------------------------------------------

aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICIO" --output json > "$TMP/servicio.json"
jq -e '(.failures | length) == 0 and .services[0].status == "ACTIVE"' "$TMP/servicio.json" > /dev/null \
  || { jq -c '.failures' "$TMP/servicio.json"; falla "el servicio $SERVICIO no existe o no está ACTIVE en $CLUSTER"; }
TD_ANTERIOR="$(jq -r '.services[0].taskDefinition' "$TMP/servicio.json")"
log "task definition actual $TD_ANTERIOR"

aws ecs describe-task-definition --task-definition "$TD_ANTERIOR" --output json > "$TMP/td-actual.json"
jq -e --arg c "$CONTENEDOR" 'any(.taskDefinition.containerDefinitions[]; .name == $c)' "$TMP/td-actual.json" > /dev/null \
  || falla "la task definition $TD_ANTERIOR no tiene el contenedor $CONTENEDOR"
[ "$(jq -r '.taskDefinition.family' "$TMP/td-actual.json")" = "$FAMILIA" ] \
  || falla "la task definition del servicio no es de la familia $FAMILIA"

jq --arg c "$CONTENEDOR" --arg img "$IMAGEN" --arg modelo "$MODELO" --arg entorno "$SLUG" --arg name "$FAMILIA" '
  .taskDefinition
  | .containerDefinitions |= map(if .name == $c then .image = $img else . end)
  | del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities,
        .registeredAt, .registeredBy, .deregisteredAt)
  | .tags = [{key: "modelo", value: $modelo}, {key: "entorno", value: $entorno}, {key: "Name", value: $name}]
' "$TMP/td-actual.json" > "$TMP/td-nueva.json"

TD_NUEVA="$(aws ecs register-task-definition --cli-input-json "file://$TMP/td-nueva.json" --query taskDefinition.taskDefinitionArn --output text)"
log "task definition nueva $TD_NUEVA"

# --- b) Migraciones -------------------------------------------------------------

ETAPA=migracion
RED="$(jq -c '.services[0].networkConfiguration' "$TMP/servicio.json")"
OVERRIDES="$(jq -nc --arg c "$CONTENEDOR" '{containerOverrides: [{name: $c, command: ["bash", "scripts/prestart.sh"]}]}')"

MIG_INICIO="$(ahora)"
aws ecs run-task --cluster "$CLUSTER" --task-definition "$TD_NUEVA" --launch-type FARGATE \
  --network-configuration "$RED" --overrides "$OVERRIDES" --started-by "$STARTED_BY" \
  --propagate-tags TASK_DEFINITION --count 1 --output json > "$TMP/run.json"
jq -e '(.failures | length) == 0 and (.tasks | length) == 1' "$TMP/run.json" > /dev/null \
  || { MIG_FIN="$(ahora)"; jq -c '.failures' "$TMP/run.json"; falla "run-task no lanzó la tarea de migraciones"; }
TAREA="$(jq -r '.tasks[0].taskArn' "$TMP/run.json")"
TAREA_ID="${TAREA##*/}"
log "migraciones en la tarea $TAREA_ID (startedBy $STARTED_BY)"

# El waiter espera hasta 10 min; si se vence, se decide con el estado que tenga la tarea.
aws ecs wait tasks-stopped --cluster "$CLUSTER" --tasks "$TAREA" || log "el waiter de tasks-stopped terminó sin éxito"
MIG_FIN="$(ahora)"
aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TAREA" --output json > "$TMP/tarea.json"
ESTADO_TAREA="$(jq -r '.tasks[0].lastStatus' "$TMP/tarea.json")"
MIG_EXIT="$(jq -r --arg c "$CONTENEDOR" '.tasks[0].containers[] | select(.name == $c) | .exitCode // empty' "$TMP/tarea.json")"

mostrar_log_tarea() {
  echo "--- log de la tarea $TAREA_ID ($LOG_GROUP, $LOG_PREFIX/$TAREA_ID)"
  aws logs get-log-events --log-group-name "$LOG_GROUP" --log-stream-name "$LOG_PREFIX/$TAREA_ID" \
    --start-from-head --output json 2> /dev/null | jq -r '.events[].message' || echo "(no se pudo leer el log)"
  echo "--- fin del log"
}

if [ "$ESTADO_TAREA" != "STOPPED" ]; then
  aws ecs stop-task --cluster "$CLUSTER" --task "$TAREA" --reason "Timeout del despliegue" > /dev/null || true
  mostrar_log_tarea
  falla "la tarea de migraciones no terminó (estado $ESTADO_TAREA); se pidió detenerla"
fi
if [ -z "$MIG_EXIT" ] || [ "$MIG_EXIT" != "0" ]; then
  STOPPED_REASON="$(jq -r '.tasks[0].stoppedReason // "-"' "$TMP/tarea.json")"
  echo "stoppedReason: $STOPPED_REASON"
  echo "reason del contenedor: $(jq -r --arg c "$CONTENEDOR" '.tasks[0].containers[] | select(.name == $c) | .reason // "-"' "$TMP/tarea.json")"
  mostrar_log_tarea
  falla "las migraciones fallaron (exitCode ${MIG_EXIT:-sin exitCode}; stoppedReason $STOPPED_REASON)"
fi
mostrar_log_tarea
log "migraciones OK (exit 0) en $((MIG_FIN - MIG_INICIO)) s"

# --- c) update-service ----------------------------------------------------------

ETAPA=update
UPD_INICIO="$(ahora)"
DEPLOY_ID="$(aws ecs update-service --cluster "$CLUSTER" --service "$SERVICIO" --task-definition "$TD_NUEVA" \
  --query 'service.deployments[?status==`PRIMARY`] | [0].id' --output text)"
log "update-service: deployment $DEPLOY_ID, esperando rolloutState COMPLETED (timeout ${TIMEOUT_UPDATE} s)"

ULTIMO=""
while :; do
  aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICIO" --output json > "$TMP/servicio.json"
  DEP="$(jq -c --arg id "$DEPLOY_ID" '.services[0].deployments[] | select(.id == $id)' "$TMP/servicio.json")"
  [ -n "$DEP" ] || { UPD_FIN="$(ahora)"; falla "el deployment $DEPLOY_ID ya no figura en el servicio"; }
  ESTADO="$(jq -r '"\(.status) \(.rolloutState) running=\(.runningCount) pending=\(.pendingCount) failed=\(.failedTasks)"' <<< "$DEP")"
  [ "$ESTADO" = "$ULTIMO" ] || { log "$ESTADO"; ULTIMO="$ESTADO"; }
  ROLLOUT="$(jq -r '.rolloutState' <<< "$DEP")"
  if [ "$ROLLOUT" = "COMPLETED" ]; then
    UPD_FIN="$(ahora)"
    [ "$(jq -r '.status' <<< "$DEP")" = "PRIMARY" ] || falla "el deployment $DEPLOY_ID completó pero ya no es PRIMARY"
    break
  fi
  if [ "$ROLLOUT" = "FAILED" ] || [ $(( $(ahora) - UPD_INICIO )) -ge "$TIMEOUT_UPDATE" ]; then
    UPD_FIN="$(ahora)"
    RAZON="$(jq -r '.rolloutStateReason // "-"' <<< "$DEP")"
    echo "rolloutStateReason: $RAZON"
    echo "últimos eventos del servicio:"
    jq -r '.services[0].events[:5][] | "  \(.createdAt) \(.message)"' "$TMP/servicio.json"
    [ "$ROLLOUT" = "FAILED" ] && falla "el deployment $DEPLOY_ID quedó FAILED ($RAZON)"
    falla "el deployment $DEPLOY_ID no completó en ${TIMEOUT_UPDATE} s (rolloutState $ROLLOUT)"
  fi
  sleep 5
done
log "servicio $SERVICIO COMPLETED con $TD_NUEVA en $((UPD_FIN - UPD_INICIO)) s"
