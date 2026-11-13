#!/usr/bin/env bash
# Destruye un entorno del modelo efímero. Corre después de esperar-turno.sh: la serialización ya
# garantizó que ningún build anterior del mismo entorno está trabajando.
#   estado    recursos en el state entornos/<slug>/terraform.tfstate, servicio <modelo>-<slug>-backend,
#             task definition, marcador disponible.json, marcas de turno ajenas, lock y revisiones ACTIVE
#             de la familia. Si no hay nada de eso: resultado "nada que destruir" (solo se borra la marca
#             propia) y exit 0
#   lock      lock huérfano: se registra y se borra (igual que en crear-entorno.sh)
#   marcador  se borra entornos/<slug>/disponible.json ANTES de tocar nada: si la destrucción falla a
#             mitad, el próximo despliegue no toma el entorno por disponible (crear-entorno.sh completa
#             con apply y reset lo que haya quedado)
#   servicio  desired 0 y ecs wait services-stable (si el servicio existe)
#   datos     run-task con la task definition del servicio (o la última ACTIVE de la familia si no hay
#             servicio) y borrar-datos.py inline (python -c) con DESTROY_CONFIRM=app_<slug con _>, en las
#             subredes <modelo>-publica-* con el SG <modelo>-tareas; exit 0 obligatorio: si no, no se
#             corre el destroy. Sin task definition: datos.borrar_datos null, motivo "sin task
#             definition", y sigue (creación parcial)
#   init/plan/apply  terraform init, plan -destroy -out y apply de ese plan, con las mismas variables y
#             el mismo anulado del perfil que crear-entorno.sh; después se verifica que el state quedó sin
#             recursos y que el servicio ya no existe
#   limpieza  marcas entornos/<slug>/turnos/*: se borran las de builds terminados; las de builds
#             IN_PROGRESS (despliegues que esperan a este) se conservan, porque sin marca esperar-turno.sh
#             de los demás entornos los esperaría; la propia, al final. Revisiones ACTIVE de la familia
#             <modelo>-<slug>-backend: deregister. entornos/<slug>/terraform.tfstate NO se borra.
#
# Parámetros (variables): MODELO, SLUG, N, CORRIDA, TERRAFORM_DIR (el entorno/ de tesis-terraform),
# BACKEND_IMAGEN_PROD (solo para satisfacer la variable backend_image de entorno/), STATES_BUCKET,
# SCRIPTS_DIR (donde está borrar-datos.py), SALIDA_JSON.
# Opcionales: CODEBUILD_BUILD_ID (identifica la marca propia), MARCAS_BUCKET (default STATES_BUCKET).
#
# Salida: siempre, también si falla, una línea JSON (en SALIDA_JSON y en stdout) con resultado
# (ok | nada que destruir | fallo), etapa (la de la falla; null si no falla), motivo, estado_inicial,
# lock_huerfano, servicio_a_cero, datos, terraform, limpieza, inicio, fin y total_seg. Fechas en UTC.
set -Eeuo pipefail

export TF_IN_AUTOMATION=1 TF_INPUT=0

ETAPA=entradas
MOTIVO=""
RESULTADO_FINAL=ok
INICIO="$(date -u +%s)"; FIN=""
ESTADO_JSON=null
TF_VERSION=""; INIT_SEG=""; PLAN_SEG=""; APPLY_SEG=""; RECURSOS_DESTRUIDOS=""
SERVICIO_SEG=""; SERVICIO_DESIRED_PREVIO=""; SERVICIO_RUNNING_PREVIO=""; SERVICIO_ACCION="sin_correr"
DATOS_TASK_DEF=""; DATOS_TASK_ARN=""; DATOS_EXIT=""; DATOS_STOP_CODE=""; DATOS_STOPPED_REASON=""; DATOS_SEG=""; DATOS_MOTIVO=""
DATOS_SUBREDES="[]"; DATOS_SG=""
LIMPIEZA_MARCADOR=""; LIMPIEZA_MARCADOR_PREVIO=""; REVISIONES_BORRADAS=""; MARCA_PROPIA_BORRADA=""
TMP="$(mktemp -d "${TMPDIR:-/tmp}/destruir-entorno.XXXXXX")"
LOCK_JSON="$TMP/lock.json"; BORRAR_JSON="$TMP/borrar-datos.json"
: > "$TMP/marcas-borradas"; : > "$TMP/marcas-conservadas"

iso() { [ -n "$1" ] && jq -nr --argjson e "$1" '$e | todate' || true; }
dif() { [ -n "$1" ] && [ -n "$2" ] && echo $(( $2 - $1 )) || true; }
json_o_null() { if [ -s "$1" ] && jq -e . "$1" > /dev/null 2>&1; then jq -c . "$1"; else echo null; fi; }
lineas_json() { jq -Rsc 'split("\n") | map(select(. != ""))' "$1"; }

finalizar() {
  local rc=$1 resultado=$RESULTADO_FINAL etapa
  set +e
  if [ "$rc" -eq 0 ]; then etapa=""; else resultado=fallo; etapa="$ETAPA"; MOTIVO="${MOTIVO:-error inesperado (exit $rc)}"; fi
  FIN="$(date -u +%s)"
  RESULTADO="$(jq -nc \
    --arg resultado "$resultado" --arg etapa "$etapa" --arg motivo "$MOTIVO" \
    --argjson estado "$ESTADO_JSON" --argjson lock "$(json_o_null "$LOCK_JSON")" \
    --arg sv_accion "$SERVICIO_ACCION" --arg sv_seg "$SERVICIO_SEG" --arg sv_desired "$SERVICIO_DESIRED_PREVIO" --arg sv_running "$SERVICIO_RUNNING_PREVIO" \
    --arg task_def "$DATOS_TASK_DEF" --arg task_arn "$DATOS_TASK_ARN" --arg exit_code "$DATOS_EXIT" --arg stop_code "$DATOS_STOP_CODE" \
    --arg stopped_reason "$DATOS_STOPPED_REASON" --arg datos_seg "$DATOS_SEG" --arg datos_motivo "$DATOS_MOTIVO" \
    --argjson subredes "$DATOS_SUBREDES" --arg sg "$DATOS_SG" --argjson borrar "$(json_o_null "$BORRAR_JSON")" \
    --arg tf_version "$TF_VERSION" --arg init_seg "$INIT_SEG" --arg plan_seg "$PLAN_SEG" --arg apply_seg "$APPLY_SEG" \
    --arg recursos_destruidos "$RECURSOS_DESTRUIDOS" \
    --arg marcador "$LIMPIEZA_MARCADOR" --arg marcador_previo "$LIMPIEZA_MARCADOR_PREVIO" \
    --argjson marcas_borradas "$(lineas_json "$TMP/marcas-borradas")" --argjson marcas_conservadas "$(lineas_json "$TMP/marcas-conservadas")" \
    --arg propia "$MARCA_PROPIA_BORRADA" --arg revisiones "$REVISIONES_BORRADAS" \
    --arg inicio "$(iso "$INICIO")" --arg fin "$(iso "$FIN")" --arg total_seg "$(dif "$INICIO" "$FIN")" \
    'def s: if . == "" then null else . end; def n: if . == "" then null else tonumber end;
     def b: if . == "" then null else . == "true" end;
     {resultado: $resultado, etapa: ($etapa | s), motivo: ($motivo | s), estado_inicial: $estado, lock_huerfano: $lock,
      servicio_a_cero: {accion: $sv_accion, seg: ($sv_seg | n), desired_previo: ($sv_desired | n), running_previo: ($sv_running | n)},
      datos: {task_definition: ($task_def | s), task_arn: ($task_arn | s), exit_code: ($exit_code | n), stop_code: ($stop_code | s),
        stopped_reason: ($stopped_reason | s), borrar_datos: $borrar, seg: ($datos_seg | n), motivo: ($datos_motivo | s),
        subredes: $subredes, security_group: ($sg | s)},
      terraform: {version: ($tf_version | s), init_seg: ($init_seg | n), plan_seg: ($plan_seg | n),
        apply_seg: ($apply_seg | n), recursos_destruidos: ($recursos_destruidos | n)},
      limpieza: {marcador: ($marcador | s), marcador_previo: ($marcador_previo | b),
        marcas: {borradas: $marcas_borradas, conservadas: $marcas_conservadas, propia_borrada: ($propia | b)},
        revisiones: ($revisiones | n)},
      inicio: $inicio, fin: $fin, total_seg: ($total_seg | n)}')"
  [ -z "${SALIDA_JSON:-}" ] || echo "$RESULTADO" > "$SALIDA_JSON"
  echo "$RESULTADO"
  rm -rf "$TMP"
  exit "$rc"
}
trap 'finalizar $?' EXIT
trap 'MOTIVO="${MOTIVO:-fallo el comando: $BASH_COMMAND}"' ERR

ahora() { date -u +%s; }
log() { echo "DESTRUIR-ENTORNO [$ETAPA] - $*"; }
falla() { MOTIVO="$*"; echo "ERROR - $*"; exit 1; }
primer_error() { { grep -m1 'Error:' "$1" || echo "sin detalle"; } | sed 's/^[│ ]*//' | cut -c1-300; }
existe_s3() {
  local rc=0
  aws s3api head-object --bucket "$1" --key "$2" > "$TMP/head.json" 2> "$TMP/head.err" || rc=$?
  [ "$rc" -ne 0 ] || return 0
  if grep -q -e '(404)' -e 'Not Found' "$TMP/head.err"; then return 1; fi
  falla "no se pudo consultar s3://$1/$2 (exit $rc): $(tr '\n' ' ' < "$TMP/head.err" | cut -c1-300)"
}
tf() {
  local nombre=$1 rc=0
  shift
  terraform -chdir="$TERRAFORM_DIR" "$@" 2>&1 | tee "$TMP/$nombre.log" || rc=$?
  [ "$rc" -eq 0 ] || falla "terraform $nombre (exit $rc): $(primer_error "$TMP/$nombre.log")"
}
# Las consultas dejan su resultado en variables o archivos (no en $(...)): así falla() corta el
# script con su motivo en vez de morir en un subshell.
# STATE_EXISTE y RECURSOS_N: instancias de recursos managed en el state (0 si no existe el objeto).
recursos_en_state() {
  STATE_EXISTE=false; RECURSOS_N=0
  if existe_s3 "$STATES_BUCKET" "$STATE_KEY"; then
    STATE_EXISTE=true
    aws s3 cp "s3://$STATES_BUCKET/$STATE_KEY" "$TMP/state.json" --only-show-errors \
      || falla "no se pudo leer el state s3://$STATES_BUCKET/$STATE_KEY"
    RECURSOS_N="$(jq '[.resources[]? | select(.mode == "managed") | .instances[]?] | length' "$TMP/state.json" 2> /dev/null)" \
      || falla "el state s3://$STATES_BUCKET/$STATE_KEY no es JSON valido"
  fi
}
# SV_ESTADO: ACTIVE, DRAINING, INACTIVE o MISSING; el describe queda en $TMP/servicio.json.
estado_servicio() {
  aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICIO_ECS" --output json > "$TMP/servicio.json" 2> "$TMP/servicio.err" \
    || falla "no se pudo consultar el servicio $SERVICIO_ECS en $CLUSTER: $(tr '\n' ' ' < "$TMP/servicio.err" | cut -c1-300)"
  SV_ESTADO="$(jq -r '.services[0].status // "MISSING"' "$TMP/servicio.json")"
}
# $TMP/revisiones.txt: ARNs de las revisiones ACTIVE de la familia exacta, de la más nueva a la más
# vieja (sin otras familias que compartan el prefijo).
revisiones_activas() {
  aws ecs list-task-definitions --family-prefix "$FAMILIA" --status ACTIVE --sort DESC --output json > "$TMP/revisiones.json" \
    || falla "no se pudo listar las task definitions ACTIVE de $FAMILIA"
  jq -r --arg f "$FAMILIA" '.taskDefinitionArns[]? | select(test(":task-definition/" + $f + ":[0-9]+$"))' "$TMP/revisiones.json" > "$TMP/revisiones.txt"
}
# $TMP/marcas-ajenas.txt: claves de las marcas de turno del entorno, sin la propia.
marcas_ajenas() {
  aws s3api list-objects-v2 --bucket "$MARCAS_BUCKET" --prefix "$MARCAS_PREFIX" --output json > "$TMP/marcas.json" \
    || falla "no se pudo listar s3://$MARCAS_BUCKET/$MARCAS_PREFIX"
  jq -r --arg propia "$MARCA_PROPIA_KEY" '.Contents[]?.Key | select(endswith(".json") and . != $propia)' "$TMP/marcas.json" > "$TMP/marcas-ajenas.txt"
}
cuenta_lineas() { grep -c . "$1" || true; }
borrar_marca_propia() {
  if [ -n "$MARCA_PROPIA_KEY" ] && existe_s3 "$MARCAS_BUCKET" "$MARCA_PROPIA_KEY"; then
    aws s3api delete-object --bucket "$MARCAS_BUCKET" --key "$MARCA_PROPIA_KEY" > /dev/null \
      || falla "no se pudo borrar la marca propia s3://$MARCAS_BUCKET/$MARCA_PROPIA_KEY"
    MARCA_PROPIA_BORRADA=true
    log "marca propia s3://$MARCAS_BUCKET/$MARCA_PROPIA_KEY borrada"
  else
    MARCA_PROPIA_BORRADA=false
    log "sin marca propia que borrar (${MARCA_PROPIA_KEY:-sin CODEBUILD_BUILD_ID})"
  fi
}

# --- Entradas -------------------------------------------------------------------

for v in MODELO SLUG N CORRIDA TERRAFORM_DIR BACKEND_IMAGEN_PROD STATES_BUCKET SCRIPTS_DIR SALIDA_JSON; do
  [ -n "${!v:-}" ] || falla "falta la variable $v"
done
MARCAS_BUCKET="${MARCAS_BUCKET:-$STATES_BUCKET}"
[[ "$MODELO" =~ ^[a-z]+$ ]] || falla "MODELO invalido ($MODELO)"
[[ "$SLUG" =~ ^[a-z0-9-]{1,20}$ ]] || falla "SLUG invalido ($SLUG)"
[[ "$N" =~ ^[0-9]+$ ]] && [ "$N" -ge 1 ] && [ "$N" -le 99 ] || falla "N tiene que ser un entero entre 1 y 99 ($N)"
[[ "$CORRIDA" =~ ^c[0-9]+$ ]] || falla "CORRIDA tiene que ser c<N> ($CORRIDA)"
[[ "$BACKEND_IMAGEN_PROD" =~ ^[^@[:space:]]+@sha256:[0-9a-f]{64}$ ]] || falla "BACKEND_IMAGEN_PROD tiene que ser <repo>@sha256:<64 hex> ($BACKEND_IMAGEN_PROD)"
for b in STATES_BUCKET MARCAS_BUCKET; do
  [[ "${!b}" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || falla "$b invalido (${!b})"
done
TFVARS_MODELO="values-$MODELO.tfvars"
BACKEND_MODELO="$TERRAFORM_DIR/backend-$MODELO.hcl"
BORRAR_PY="$SCRIPTS_DIR/borrar-datos.py"
for f in "$TERRAFORM_DIR/$TFVARS_MODELO" "$BACKEND_MODELO" "$BORRAR_PY"; do
  [ -f "$f" ] || falla "no existe $f"
done
for cmd in terraform aws jq; do
  command -v "$cmd" > /dev/null 2>&1 || falla "falta el comando $cmd"
done

STATE_KEY="entornos/$SLUG/terraform.tfstate"
LOCK_KEY="$STATE_KEY.tflock"
MARCADOR_KEY="entornos/$SLUG/disponible.json"
MARCAS_PREFIX="entornos/$SLUG/turnos/"
MARCA_PROPIA_KEY=""; [ -z "${CODEBUILD_BUILD_ID:-}" ] || MARCA_PROPIA_KEY="$MARCAS_PREFIX$CODEBUILD_BUILD_ID.json"
CLUSTER="$MODELO-cluster"
SERVICIO_ECS="$MODELO-$SLUG-backend"
FAMILIA="$MODELO-$SLUG-backend"
DB="app_${SLUG//-/_}"
echo "DESTRUIR-ENTORNO - modelo $MODELO, slug $SLUG, n $N, corrida $CORRIDA, base $DB"

# --- Estado inicial ---------------------------------------------------------------

ETAPA=estado
recursos_en_state
RECURSOS="$RECURSOS_N"
estado_servicio
SV_EXISTE=false; [ "$SV_ESTADO" = "ACTIVE" ] && SV_EXISTE=true
if [ "$SV_EXISTE" = true ]; then
  DATOS_TASK_DEF="$(jq -r '.services[0].taskDefinition // empty' "$TMP/servicio.json")"
  SERVICIO_DESIRED_PREVIO="$(jq -r '.services[0].desiredCount' "$TMP/servicio.json")"
  SERVICIO_RUNNING_PREVIO="$(jq -r '.services[0].runningCount' "$TMP/servicio.json")"
fi
revisiones_activas
REVISIONES_INICIALES="$(cuenta_lineas "$TMP/revisiones.txt")"
[ -n "$DATOS_TASK_DEF" ] || DATOS_TASK_DEF="$(head -n1 "$TMP/revisiones.txt")"
MARCADOR_EXISTE=false; existe_s3 "$STATES_BUCKET" "$MARCADOR_KEY" && MARCADOR_EXISTE=true
LOCK_EXISTE=false; existe_s3 "$STATES_BUCKET" "$LOCK_KEY" && LOCK_EXISTE=true
marcas_ajenas
MARCAS_AJENAS="$(cuenta_lineas "$TMP/marcas-ajenas.txt")"
ESTADO_JSON="$(jq -nc --argjson recursos "$RECURSOS" --arg state_existe "$STATE_EXISTE" --arg servicio "$SV_ESTADO" \
  --arg task_def "$DATOS_TASK_DEF" --argjson revisiones "$REVISIONES_INICIALES" --arg marcador "$MARCADOR_EXISTE" \
  --arg lock "$LOCK_EXISTE" --argjson marcas "$MARCAS_AJENAS" \
  '{recursos_state: $recursos, state_existe: ($state_existe == "true"), servicio: $servicio,
    task_definition: (if $task_def == "" then null else $task_def end), revisiones_activas: $revisiones,
    marcador: ($marcador == "true"), lock: ($lock == "true"), marcas_ajenas: $marcas}')"
log "estado inicial $ESTADO_JSON"

if [ "$RECURSOS" -eq 0 ] && [ "$SV_ESTADO" != "ACTIVE" ] && [ "$SV_ESTADO" != "DRAINING" ] && [ "$MARCADOR_EXISTE" = false ] \
  && [ "$MARCAS_AJENAS" -eq 0 ] && [ "$REVISIONES_INICIALES" -eq 0 ] && [ "$LOCK_EXISTE" = false ]; then
  log "nada que destruir: el state no tiene recursos y no hay servicio, task definitions, marcador, lock ni marcas ajenas"
  ETAPA=limpieza
  LIMPIEZA_MARCADOR_PREVIO=false; REVISIONES_BORRADAS=0
  borrar_marca_propia
  RESULTADO_FINAL="nada que destruir"
  exit 0
fi

# --- Lock huérfano ----------------------------------------------------------------

ETAPA=lock
if [ "$LOCK_EXISTE" = true ] && existe_s3 "$STATES_BUCKET" "$LOCK_KEY"; then
  LOCK_MODIFICADO="$(jq -r '.LastModified // empty' "$TMP/head.json" | sed -E 's/\+00:00$/Z/')"
  DETECTADO="$(ahora)"
  aws s3 cp "s3://$STATES_BUCKET/$LOCK_KEY" "$TMP/lock.contenido" --only-show-errors \
    || falla "no se pudo leer el lock huerfano s3://$STATES_BUCKET/$LOCK_KEY"
  log "lock huerfano s3://$STATES_BUCKET/$LOCK_KEY (LastModified $LOCK_MODIFICADO):"
  cat "$TMP/lock.contenido"; echo
  aws s3api delete-object --bucket "$STATES_BUCKET" --key "$LOCK_KEY" > /dev/null \
    || falla "no se pudo borrar el lock huerfano s3://$STATES_BUCKET/$LOCK_KEY"
  if existe_s3 "$STATES_BUCKET" "$LOCK_KEY"; then falla "el lock s3://$STATES_BUCKET/$LOCK_KEY sigue existiendo despues de borrarlo"; fi
  jq -nc --arg uri "s3://$STATES_BUCKET/$LOCK_KEY" --arg last_modified "$LOCK_MODIFICADO" \
    --rawfile contenido "$TMP/lock.contenido" --arg detectado_at "$(iso "$DETECTADO")" --arg borrado_at "$(iso "$(ahora)")" \
    '{uri: $uri, last_modified: (if $last_modified == "" then null else $last_modified end),
      contenido: ($contenido | fromjson? // $contenido), detectado_at: $detectado_at, borrado_at: $borrado_at}' > "$LOCK_JSON"
  log "lock huerfano borrado"
else
  log "sin lock en s3://$STATES_BUCKET/$LOCK_KEY"
fi

# --- Marcador (antes de tocar el entorno) ---------------------------------------------

ETAPA=marcador
LIMPIEZA_MARCADOR_PREVIO="$MARCADOR_EXISTE"
if [ "$MARCADOR_EXISTE" = true ]; then
  aws s3api delete-object --bucket "$STATES_BUCKET" --key "$MARCADOR_KEY" > /dev/null \
    || falla "no se pudo borrar el marcador s3://$STATES_BUCKET/$MARCADOR_KEY"
  if existe_s3 "$STATES_BUCKET" "$MARCADOR_KEY"; then falla "el marcador s3://$STATES_BUCKET/$MARCADOR_KEY sigue existiendo despues de borrarlo"; fi
  LIMPIEZA_MARCADOR="s3://$STATES_BUCKET/$MARCADOR_KEY"
  log "marcador $LIMPIEZA_MARCADOR borrado: el entorno ya no figura como disponible"
else
  log "sin marcador s3://$STATES_BUCKET/$MARCADOR_KEY"
fi

# --- Servicio a 0 -----------------------------------------------------------------------

ETAPA=servicio
if [ "$SV_EXISTE" = true ]; then
  SERVICIO_ACCION=desired_0
  log "servicio $SERVICIO_ECS (desired $SERVICIO_DESIRED_PREVIO, running $SERVICIO_RUNNING_PREVIO): desired 0"
  T0="$(ahora)"
  aws ecs update-service --cluster "$CLUSTER" --service "$SERVICIO_ECS" --desired-count 0 --output json > /dev/null \
    || falla "no se pudo llevar el servicio $SERVICIO_ECS a desired 0"
  aws ecs wait services-stable --cluster "$CLUSTER" --services "$SERVICIO_ECS" \
    || { SERVICIO_SEG="$(dif "$T0" "$(ahora)")"; falla "el servicio $SERVICIO_ECS no quedo estable en desired 0 en el tiempo del waiter"; }
  SERVICIO_SEG="$(dif "$T0" "$(ahora)")"
  log "servicio en 0 y estable ($SERVICIO_SEG s)"
else
  SERVICIO_ACCION="sin_servicio"
  log "sin servicio $SERVICIO_ECS activo en $CLUSTER ($SV_ESTADO)"
fi

# --- Borrado de datos -------------------------------------------------------------------

ETAPA=datos
if [ -z "$DATOS_TASK_DEF" ]; then
  DATOS_MOTIVO="sin task definition"
  log "sin task definition del servicio ni revisiones ACTIVE de $FAMILIA: no se borran datos (creacion parcial)"
else
  [[ "$DATOS_TASK_DEF" =~ ^arn:aws:ecs:[a-z0-9-]+:[0-9]{12}:task-definition/${FAMILIA}:[0-9]+$ ]] \
    || falla "la task definition $DATOS_TASK_DEF no es de la familia $FAMILIA"
  aws ec2 describe-subnets --filters "Name=tag:Name,Values=$MODELO-publica-*" \
    --query 'Subnets[].{id: SubnetId, vpc: VpcId}' --output json > "$TMP/subredes.json"
  aws ec2 describe-security-groups --filters "Name=group-name,Values=$MODELO-tareas" \
    --query 'SecurityGroups[].{id: GroupId, vpc: VpcId}' --output json > "$TMP/sg.json"
  [ "$(jq 'length' "$TMP/subredes.json")" -ge 1 ] || falla "no hay subredes con tag Name $MODELO-publica-*"
  [ "$(jq 'length' "$TMP/sg.json")" -eq 1 ] || falla "se esperaba un security group $MODELO-tareas y hay $(jq -c 'map(.id)' "$TMP/sg.json")"
  DATOS_SG="$(jq -r '.[0].id' "$TMP/sg.json")"
  VPC_SG="$(jq -r '.[0].vpc' "$TMP/sg.json")"
  [ "$(jq -r --arg v "$VPC_SG" 'map(select(.vpc != $v)) | length' "$TMP/subredes.json")" -eq 0 ] \
    || falla "las subredes $MODELO-publica-* no estan todas en la VPC del SG $DATOS_SG ($VPC_SG): $(jq -c . "$TMP/subredes.json")"
  DATOS_SUBREDES="$(jq -c 'map(.id) | sort' "$TMP/subredes.json")"
  RED="$(jq -nc --argjson s "$DATOS_SUBREDES" --arg sg "$DATOS_SG" '{awsvpcConfiguration: {subnets: $s, securityGroups: [$sg], assignPublicIp: "ENABLED"}}')"
  OVERRIDES="$(jq -nc --rawfile code "$BORRAR_PY" --arg db "$DB" \
    '{containerOverrides: [{name: "backend", command: ["python", "-c", $code], environment: [{name: "DESTROY_CONFIRM", value: $db}]}]}')"
  # Límite de ECS para overrides: 8192 caracteres.
  [ "${#OVERRIDES}" -le 8000 ] || falla "los overrides con borrar-datos.py inline tienen ${#OVERRIDES} caracteres (limite de ECS 8192)"
  log "task definition $DATOS_TASK_DEF, subredes $DATOS_SUBREDES, SG $DATOS_SG, DESTROY_CONFIRM=$DB, overrides ${#OVERRIDES} caracteres"
  T0="$(ahora)"
  aws ecs run-task --cluster "$CLUSTER" --task-definition "$DATOS_TASK_DEF" --launch-type FARGATE --count 1 \
    --started-by destruir-entorno --network-configuration "$RED" --overrides "$OVERRIDES" --output json > "$TMP/run-task.json" \
    || falla "fallo ecs run-task del borrado de datos"
  [ "$(jq '.failures | length' "$TMP/run-task.json")" -eq 0 ] || falla "ecs run-task devolvio failures: $(jq -c .failures "$TMP/run-task.json" | cut -c1-300)"
  DATOS_TASK_ARN="$(jq -r '.tasks[0].taskArn // empty' "$TMP/run-task.json")"
  [ -n "$DATOS_TASK_ARN" ] || falla "ecs run-task no devolvio taskArn"
  log "tarea $DATOS_TASK_ARN, esperando tasks-stopped"
  aws ecs wait tasks-stopped --cluster "$CLUSTER" --tasks "$DATOS_TASK_ARN" \
    || { DATOS_SEG="$(dif "$T0" "$(ahora)")"; falla "la tarea de borrado $DATOS_TASK_ARN no se detuvo en el tiempo del waiter"; }
  DATOS_SEG="$(dif "$T0" "$(ahora)")"
  aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$DATOS_TASK_ARN" --output json > "$TMP/datos-task.json"
  DATOS_STOP_CODE="$(jq -r '.tasks[0].stopCode // empty' "$TMP/datos-task.json")"
  DATOS_STOPPED_REASON="$(jq -r '.tasks[0].stoppedReason // empty' "$TMP/datos-task.json")"
  DATOS_EXIT="$(jq -r '[.tasks[0].containers[]? | select(.name == "backend") | .exitCode][0] // empty' "$TMP/datos-task.json")"
  # Logs (awslogs, grupo /ecs/<modelo>, stream <slug>/backend/<id>): la línea BORRAR-DATOS va al JSON.
  # Pueden tardar unos segundos en aparecer: hasta 3 intentos.
  for intento in 1 2 3; do
    if aws logs get-log-events --log-group-name "/ecs/$MODELO" --log-stream-name "$SLUG/backend/${DATOS_TASK_ARN##*/}" \
      --start-from-head --query 'events[].message' --output json > "$TMP/datos-log.json" 2> /dev/null \
      && jq -r '.[]' "$TMP/datos-log.json" | grep -m1 '^BORRAR-DATOS ' | sed 's/^BORRAR-DATOS //' > "$TMP/borrar.linea" \
      && jq -e . "$TMP/borrar.linea" > /dev/null 2>&1; then
      jq -c . "$TMP/borrar.linea" > "$BORRAR_JSON"
      break
    fi
    [ "$intento" -eq 3 ] || sleep "${LOGS_REINTENTO_SEG:-5}"
  done
  if [ -s "$TMP/datos-log.json" ]; then log "logs del borrado:"; jq -r '.[]' "$TMP/datos-log.json"; fi
  [ -s "$BORRAR_JSON" ] || log "no se pudo leer la linea BORRAR-DATOS de los logs (no hace fallar; manda el exit code)"
  if [ "$DATOS_EXIT" != "0" ]; then
    DATOS_MOTIVO="borrar-datos.py termino con exit ${DATOS_EXIT:-<sin exit>}"
    falla "$DATOS_MOTIVO (stopCode ${DATOS_STOP_CODE:-<sin stopCode>}, ${DATOS_STOPPED_REASON:-sin stoppedReason}): $(jq -r '.motivo // "sin motivo"' "$BORRAR_JSON" 2> /dev/null || echo "sin linea BORRAR-DATOS"); no se corre el destroy"
  fi
  log "datos borrados ($DATOS_SEG s): $(cat "$BORRAR_JSON" 2> /dev/null || echo "sin linea BORRAR-DATOS")"
fi

# --- terraform init -----------------------------------------------------------------

ETAPA=init
BUCKET_HCL="$(sed -nE 's/^[[:space:]]*bucket[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/p' "$BACKEND_MODELO")"
[ "$BUCKET_HCL" = "$STATES_BUCKET" ] || falla "el bucket de $BACKEND_MODELO (${BUCKET_HCL:-<sin bucket>}) no es STATES_BUCKET ($STATES_BUCKET)"
grep -Ev '^[[:space:]]*profile[[:space:]]*=' "$BACKEND_MODELO" > "$TMP/backend-ci.hcl"
printf 'aws_profile = null\n' > "$TMP/ci.tfvars"
TF_VERSION="$(terraform version -json | jq -r '.terraform_version')"
log "terraform $TF_VERSION, backend s3://$STATES_BUCKET/$STATE_KEY (backend-$MODELO.hcl sin profile)"
T0="$(ahora)"
tf init init -input=false -no-color -reconfigure -backend-config="$TMP/backend-ci.hcl" -backend-config="key=$STATE_KEY"
INIT_SEG="$(dif "$T0" "$(ahora)")"

# --- terraform plan -destroy y apply ----------------------------------------------------

ETAPA=plan
T0="$(ahora)"
tf plan plan -destroy -input=false -no-color -out="$TMP/destruir.tfplan" \
  -var-file="$TFVARS_MODELO" -var-file="$TMP/ci.tfvars" \
  -var "slug=$SLUG" -var "n=$N" -var "backend_image=$BACKEND_IMAGEN_PROD" -var "corrida=$CORRIDA"
PLAN_SEG="$(dif "$T0" "$(ahora)")"
terraform -chdir="$TERRAFORM_DIR" show -json "$TMP/destruir.tfplan" > "$TMP/plan.json" \
  || falla "no se pudo leer el plan con terraform show -json"
PLAN_DESTRUIR="$(jq '[.resource_changes[]? | select(.change.actions | index("delete"))] | length' "$TMP/plan.json")"
PLAN_OTROS="$(jq '[.resource_changes[]? | select(.change.actions != ["delete"] and .change.actions != ["no-op"])] | length' "$TMP/plan.json")"
[ "$PLAN_OTROS" -eq 0 ] || falla "el plan -destroy tiene $PLAN_OTROS cambios que no son delete"
log "plan -destroy: $PLAN_DESTRUIR a destruir ($PLAN_SEG s)"

ETAPA=apply
T0="$(ahora)"
tf apply apply -input=false -no-color "$TMP/destruir.tfplan"
APPLY_SEG="$(dif "$T0" "$(ahora)")"
RECURSOS_DESTRUIDOS="$PLAN_DESTRUIR"
log "apply ok ($APPLY_SEG s, $RECURSOS_DESTRUIDOS recursos destruidos)"
recursos_en_state
[ "$RECURSOS_N" -eq 0 ] || falla "despues del destroy el state todavia tiene $RECURSOS_N recursos"
estado_servicio
[ "$SV_ESTADO" != "ACTIVE" ] || falla "el servicio $SERVICIO_ECS sigue ACTIVE despues del destroy (fuera del state)"

# --- Limpieza fuera de Terraform -------------------------------------------------------

ETAPA=limpieza
marcas_ajenas
while IFS= read -r key; do
  [ -n "$key" ] || continue
  id="$(basename "$key" .json)"
  estado="$(aws codebuild batch-get-builds --ids "$id" --query 'builds[0].buildStatus' --output text 2> /dev/null || true)"
  if [ "$estado" = "IN_PROGRESS" ]; then
    echo "$key" >> "$TMP/marcas-conservadas"
    log "marca $key conservada: el build $id sigue IN_PROGRESS"
  else
    aws s3api delete-object --bucket "$MARCAS_BUCKET" --key "$key" > /dev/null \
      || falla "no se pudo borrar la marca s3://$MARCAS_BUCKET/$key"
    echo "$key" >> "$TMP/marcas-borradas"
  fi
done < "$TMP/marcas-ajenas.txt"
log "marcas ajenas: $(cuenta_lineas "$TMP/marcas-borradas") borradas, $(cuenta_lineas "$TMP/marcas-conservadas") conservadas"
REVISIONES_BORRADAS=0
revisiones_activas
while IFS= read -r arn; do
  [ -n "$arn" ] || continue
  aws ecs deregister-task-definition --task-definition "$arn" --output json > /dev/null \
    || falla "no se pudo desregistrar $arn"
  REVISIONES_BORRADAS=$((REVISIONES_BORRADAS + 1))
  log "desregistrada $arn"
done < "$TMP/revisiones.txt"
log "$REVISIONES_BORRADAS revisiones ACTIVE de $FAMILIA desregistradas; s3://$STATES_BUCKET/$STATE_KEY se conserva"
borrar_marca_propia
log "entorno $SLUG destruido"
