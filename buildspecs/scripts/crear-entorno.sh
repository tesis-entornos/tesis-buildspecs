#!/usr/bin/env bash
# Crea un entorno del modelo efímero (lo mismo que se probó a mano con release-c0-1 el 2026-11-12):
#   lock      si existe entornos/<slug>/terraform.tfstate.tflock es huérfano (la serialización ya
#             garantizó que nadie más trabaja en el entorno): se registra (contenido y fecha) y se borra
#   init      terraform init de entorno/ con el backend del modelo sin la línea profile y
#             key=entornos/<slug>/terraform.tfstate
#   plan      terraform plan -out con values-<modelo>.tfvars más un tfvars de CI (aws_profile = null),
#             slug, n, backend_image (la de producción) y corrida
#   apply     terraform apply de ese plan (idempotente: completa una creación parcial)
#   reset     run-task de la task definition del servicio <modelo>-<slug>-backend con
#             python scripts/reset_baseline.py y RESET_CONFIRM=app_<slug con _>, en las subredes
#             públicas (tag Name <modelo>-publica-*) con el SG de tareas (<modelo>-tareas) e IP
#             pública; ecs wait tasks-stopped; exit 0 obligatorio
#   frontend  desplegar-frontend.sh con la imagen de producción del frontend
#   espera    esperar-entorno.sh
#   marcador  s3://<STATES_BUCKET>/entornos/<slug>/disponible.json: solo si todo lo anterior salió bien
#
# Perfil AWS: values-<modelo>.tfvars y backend-<modelo>.hcl traen profile = tf-<modelo>, que en
# CodeBuild no existe. Sin tocar el repo terraform se anula así:
#   - variables: un tfvars de CI con aws_profile = null, pasado después del del modelo (el último gana;
#     la variable admite null: el provider y el remote state de base usan las credenciales del entorno)
#   - backend: una copia de backend-<modelo>.hcl sin la línea profile (el backend no lee variables)
# Los dos archivos se generan en un directorio temporal, no en TERRAFORM_DIR.
#
# Parámetros (variables): MODELO, SLUG, N, CORRIDA, TERRAFORM_DIR (el entorno/ de tesis-terraform),
# BACKEND_IMAGEN_PROD y FRONTEND_IMAGEN_PROD (<repo>@sha256:<digest>), STATES_BUCKET, SCRIPTS_DIR
# (donde están desplegar-frontend.sh y esperar-entorno.sh), SALIDA_JSON.
# Opcionales (solo van al marcador): RAMA, CODEBUILD_BUILD_ID.
# Los dos scripts reutilizados reciben MODELO, SLUG, SALIDA_JSON y, el del frontend, IMAGEN.
#
# Salida: siempre, también si falla, una línea JSON (en SALIDA_JSON y en stdout) con resultado
# (ok | fallo), etapa (la de la falla; null si ok), motivo, lock_huerfano, terraform, reset, frontend y
# espera (el JSON de cada script o null), marcador (uri o null), inicio, fin y total_seg. Fechas en UTC.
set -Eeuo pipefail

export TF_IN_AUTOMATION=1 TF_INPUT=0

ETAPA=entradas
MOTIVO=""
INICIO="$(date -u +%s)"; FIN=""
TF_VERSION=""; INIT_SEG=""; PLAN_SEG=""; APPLY_SEG=""; RECURSOS_CREADOS=""
PLAN_CREAR=""; PLAN_MODIFICAR=""; PLAN_DESTRUIR=""
RESET_TASK_ARN=""; RESET_EXIT=""; RESET_STOP_CODE=""; RESET_STOPPED_REASON=""; RESET_SEG=""
RESET_TASK_DEF=""; RESET_SUBREDES="[]"; RESET_SG=""
MARCADOR_URI=""
TMP="$(mktemp -d "${TMPDIR:-/tmp}/crear-entorno.XXXXXX")"
LOCK_JSON="$TMP/lock.json"; FRONTEND_JSON="$TMP/frontend.json"; ESPERA_JSON="$TMP/espera.json"

iso() { [ -n "$1" ] && jq -nr --argjson e "$1" '$e | todate' || true; }
dif() { [ -n "$1" ] && [ -n "$2" ] && echo $(( $2 - $1 )) || true; }
json_o_null() { if [ -s "$1" ] && jq -e . "$1" > /dev/null 2>&1; then jq -c . "$1"; else echo null; fi; }

finalizar() {
  local rc=$1 resultado=ok etapa
  set +e
  if [ "$rc" -eq 0 ]; then etapa=""; else resultado=fallo; etapa="$ETAPA"; MOTIVO="${MOTIVO:-error inesperado (exit $rc)}"; fi
  FIN="$(date -u +%s)"
  RESULTADO="$(jq -nc \
    --arg resultado "$resultado" --arg etapa "$etapa" --arg motivo "$MOTIVO" \
    --argjson lock "$(json_o_null "$LOCK_JSON")" \
    --arg tf_version "$TF_VERSION" --arg init_seg "$INIT_SEG" --arg plan_seg "$PLAN_SEG" --arg apply_seg "$APPLY_SEG" \
    --arg recursos_creados "$RECURSOS_CREADOS" --arg plan_crear "$PLAN_CREAR" --arg plan_modificar "$PLAN_MODIFICAR" --arg plan_destruir "$PLAN_DESTRUIR" \
    --arg task_arn "$RESET_TASK_ARN" --arg exit_code "$RESET_EXIT" --arg stop_code "$RESET_STOP_CODE" \
    --arg stopped_reason "$RESET_STOPPED_REASON" --arg reset_seg "$RESET_SEG" --arg task_def "$RESET_TASK_DEF" \
    --argjson subredes "$RESET_SUBREDES" --arg sg "$RESET_SG" \
    --argjson frontend "$(json_o_null "$FRONTEND_JSON")" --argjson espera "$(json_o_null "$ESPERA_JSON")" \
    --arg marcador "$MARCADOR_URI" \
    --arg inicio "$(iso "$INICIO")" --arg fin "$(iso "$FIN")" --arg total_seg "$(dif "$INICIO" "$FIN")" \
    'def s: if . == "" then null else . end; def n: if . == "" then null else tonumber end;
     {resultado: $resultado, etapa: ($etapa | s), motivo: ($motivo | s), lock_huerfano: $lock,
      terraform: {version: ($tf_version | s), init_seg: ($init_seg | n), plan_seg: ($plan_seg | n),
        apply_seg: ($apply_seg | n), recursos_creados: ($recursos_creados | n),
        plan: (if $plan_crear == "" then null else {crear: ($plan_crear | n), modificar: ($plan_modificar | n), destruir: ($plan_destruir | n)} end)},
      reset: {task_arn: ($task_arn | s), exit_code: ($exit_code | n), stop_code: ($stop_code | s),
        stopped_reason: ($stopped_reason | s), seg: ($reset_seg | n), task_definition: ($task_def | s),
        subredes: $subredes, security_group: ($sg | s)},
      frontend: $frontend, espera: $espera, marcador: ($marcador | s),
      inicio: $inicio, fin: $fin, total_seg: ($total_seg | n)}')"
  [ -z "${SALIDA_JSON:-}" ] || echo "$RESULTADO" > "$SALIDA_JSON"
  echo "$RESULTADO"
  rm -rf "$TMP"
  exit "$rc"
}
trap 'finalizar $?' EXIT
trap 'MOTIVO="${MOTIVO:-fallo el comando: $BASH_COMMAND}"' ERR

ahora() { date -u +%s; }
log() { echo "CREAR-ENTORNO [$ETAPA] - $*"; }
falla() { MOTIVO="$*"; echo "ERROR - $*"; exit 1; }
# Primera línea "Error: ..." de un log de terraform (sin el marco │ de la salida).
primer_error() { { grep -m1 'Error:' "$1" || echo "sin detalle"; } | sed 's/^[│ ]*//' | cut -c1-300; }
# 0 si el objeto existe (head-object en $TMP/head.json), 1 si no existe (404); otro error, falla.
existe_s3() {
  local rc=0
  aws s3api head-object --bucket "$1" --key "$2" > "$TMP/head.json" 2> "$TMP/head.err" || rc=$?
  [ "$rc" -ne 0 ] || return 0
  if grep -q -e '(404)' -e 'Not Found' "$TMP/head.err"; then return 1; fi
  falla "no se pudo consultar s3://$1/$2 (exit $rc): $(tr '\n' ' ' < "$TMP/head.err" | cut -c1-300)"
}
# terraform en TERRAFORM_DIR con la salida en el log del build y en $TMP/<nombre>.log.
tf() {
  local nombre=$1 rc=0
  shift
  terraform -chdir="$TERRAFORM_DIR" "$@" 2>&1 | tee "$TMP/$nombre.log" || rc=$?
  [ "$rc" -eq 0 ] || falla "terraform $nombre (exit $rc): $(primer_error "$TMP/$nombre.log")"
}

# --- Entradas -------------------------------------------------------------------

for v in MODELO SLUG N CORRIDA TERRAFORM_DIR BACKEND_IMAGEN_PROD FRONTEND_IMAGEN_PROD STATES_BUCKET SCRIPTS_DIR SALIDA_JSON; do
  [ -n "${!v:-}" ] || falla "falta la variable $v"
done
[[ "$MODELO" =~ ^[a-z]+$ ]] || falla "MODELO invalido ($MODELO)"
[[ "$SLUG" =~ ^[a-z0-9-]{1,20}$ ]] || falla "SLUG invalido ($SLUG)"
[[ "$N" =~ ^[0-9]+$ ]] && [ "$N" -ge 1 ] && [ "$N" -le 99 ] || falla "N tiene que ser un entero entre 1 y 99 ($N)"
[[ "$CORRIDA" =~ ^c[0-9]+$ ]] || falla "CORRIDA tiene que ser c<N> ($CORRIDA)"
for v in BACKEND_IMAGEN_PROD FRONTEND_IMAGEN_PROD; do
  [[ "${!v}" =~ ^[^@[:space:]]+@sha256:[0-9a-f]{64}$ ]] || falla "$v tiene que ser <repo>@sha256:<64 hex> (${!v})"
done
[[ "$STATES_BUCKET" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || falla "STATES_BUCKET invalido ($STATES_BUCKET)"
TFVARS_MODELO="values-$MODELO.tfvars"
BACKEND_MODELO="$TERRAFORM_DIR/backend-$MODELO.hcl"
for f in "$TERRAFORM_DIR/$TFVARS_MODELO" "$BACKEND_MODELO" "$SCRIPTS_DIR/desplegar-frontend.sh" "$SCRIPTS_DIR/esperar-entorno.sh"; do
  [ -f "$f" ] || falla "no existe $f"
done
for cmd in terraform aws jq docker curl; do
  command -v "$cmd" > /dev/null 2>&1 || falla "falta el comando $cmd"
done

STATE_KEY="entornos/$SLUG/terraform.tfstate"
LOCK_KEY="$STATE_KEY.tflock"
MARCADOR_KEY="entornos/$SLUG/disponible.json"
CLUSTER="$MODELO-cluster"
SERVICIO_ECS="$MODELO-$SLUG-backend"
DB="app_${SLUG//-/_}"
echo "CREAR-ENTORNO - modelo $MODELO, slug $SLUG, n $N, corrida $CORRIDA"
echo "CREAR-ENTORNO - backend $BACKEND_IMAGEN_PROD, frontend $FRONTEND_IMAGEN_PROD"

# --- Lock huérfano ----------------------------------------------------------------

ETAPA=lock
if existe_s3 "$STATES_BUCKET" "$LOCK_KEY"; then
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

# --- terraform plan y apply -----------------------------------------------------------

ETAPA=plan
T0="$(ahora)"
tf plan plan -input=false -no-color -out="$TMP/entorno.tfplan" \
  -var-file="$TFVARS_MODELO" -var-file="$TMP/ci.tfvars" \
  -var "slug=$SLUG" -var "n=$N" -var "backend_image=$BACKEND_IMAGEN_PROD" -var "corrida=$CORRIDA"
PLAN_SEG="$(dif "$T0" "$(ahora)")"
terraform -chdir="$TERRAFORM_DIR" show -json "$TMP/entorno.tfplan" > "$TMP/plan.json" \
  || falla "no se pudo leer el plan con terraform show -json"
cuenta() { jq --arg a "$1" '[.resource_changes[]? | select(.change.actions | index($a))] | length' "$TMP/plan.json"; }
PLAN_CREAR="$(cuenta create)"; PLAN_MODIFICAR="$(cuenta update)"; PLAN_DESTRUIR="$(cuenta delete)"
log "plan: $PLAN_CREAR a crear, $PLAN_MODIFICAR a modificar, $PLAN_DESTRUIR a destruir ($PLAN_SEG s)"

ETAPA=apply
T0="$(ahora)"
tf apply apply -input=false -no-color "$TMP/entorno.tfplan"
APPLY_SEG="$(dif "$T0" "$(ahora)")"
RECURSOS_CREADOS="$PLAN_CREAR"
log "apply ok ($APPLY_SEG s, $RECURSOS_CREADOS recursos creados)"

# --- Reset de la línea base -----------------------------------------------------------

ETAPA=reset
RESET_TASK_DEF="$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICIO_ECS" --query 'services[0].taskDefinition' --output text)"
[[ "$RESET_TASK_DEF" =~ ^arn:aws:ecs:[a-z0-9-]+:[0-9]{12}:task-definition/${SERVICIO_ECS}:[0-9]+$ ]] \
  || falla "no se pudo leer la task definition del servicio $SERVICIO_ECS en $CLUSTER ($RESET_TASK_DEF)"
aws ec2 describe-subnets --filters "Name=tag:Name,Values=$MODELO-publica-*" \
  --query 'Subnets[].{id: SubnetId, vpc: VpcId}' --output json > "$TMP/subredes.json"
aws ec2 describe-security-groups --filters "Name=group-name,Values=$MODELO-tareas" \
  --query 'SecurityGroups[].{id: GroupId, vpc: VpcId}' --output json > "$TMP/sg.json"
[ "$(jq 'length' "$TMP/subredes.json")" -ge 1 ] || falla "no hay subredes con tag Name $MODELO-publica-*"
[ "$(jq 'length' "$TMP/sg.json")" -eq 1 ] || falla "se esperaba un security group $MODELO-tareas y hay $(jq -c 'map(.id)' "$TMP/sg.json")"
RESET_SG="$(jq -r '.[0].id' "$TMP/sg.json")"
VPC_SG="$(jq -r '.[0].vpc' "$TMP/sg.json")"
[ "$(jq -r --arg v "$VPC_SG" 'map(select(.vpc != $v)) | length' "$TMP/subredes.json")" -eq 0 ] \
  || falla "las subredes $MODELO-publica-* no estan todas en la VPC del SG $RESET_SG ($VPC_SG): $(jq -c . "$TMP/subredes.json")"
RESET_SUBREDES="$(jq -c 'map(.id) | sort' "$TMP/subredes.json")"
log "task definition $RESET_TASK_DEF, subredes $RESET_SUBREDES, SG $RESET_SG, RESET_CONFIRM=$DB"
RED="$(jq -nc --argjson s "$RESET_SUBREDES" --arg sg "$RESET_SG" '{awsvpcConfiguration: {subnets: $s, securityGroups: [$sg], assignPublicIp: "ENABLED"}}')"
OVERRIDES="$(jq -nc --arg db "$DB" '{containerOverrides: [{name: "backend", command: ["python", "scripts/reset_baseline.py"], environment: [{name: "RESET_CONFIRM", value: $db}]}]}')"
T0="$(ahora)"
aws ecs run-task --cluster "$CLUSTER" --task-definition "$RESET_TASK_DEF" --launch-type FARGATE --count 1 \
  --started-by crear-entorno --network-configuration "$RED" --overrides "$OVERRIDES" --output json > "$TMP/run-task.json" \
  || falla "fallo ecs run-task del reset"
[ "$(jq '.failures | length' "$TMP/run-task.json")" -eq 0 ] || falla "ecs run-task devolvio failures: $(jq -c .failures "$TMP/run-task.json" | cut -c1-300)"
RESET_TASK_ARN="$(jq -r '.tasks[0].taskArn // empty' "$TMP/run-task.json")"
[ -n "$RESET_TASK_ARN" ] || falla "ecs run-task no devolvio taskArn"
log "tarea $RESET_TASK_ARN, esperando tasks-stopped"
aws ecs wait tasks-stopped --cluster "$CLUSTER" --tasks "$RESET_TASK_ARN" \
  || { RESET_SEG="$(dif "$T0" "$(ahora)")"; falla "la tarea de reset $RESET_TASK_ARN no se detuvo en el tiempo del waiter"; }
RESET_SEG="$(dif "$T0" "$(ahora)")"
aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$RESET_TASK_ARN" --output json > "$TMP/reset-task.json"
RESET_STOP_CODE="$(jq -r '.tasks[0].stopCode // empty' "$TMP/reset-task.json")"
RESET_STOPPED_REASON="$(jq -r '.tasks[0].stoppedReason // empty' "$TMP/reset-task.json")"
RESET_EXIT="$(jq -r '[.tasks[0].containers[]? | select(.name == "backend") | .exitCode][0] // empty' "$TMP/reset-task.json")"
# Logs del contenedor (awslogs, grupo /ecs/<modelo>, stream <slug>/backend/<id>): solo para el log del build.
if aws logs get-log-events --log-group-name "/ecs/$MODELO" --log-stream-name "$SLUG/backend/${RESET_TASK_ARN##*/}" \
  --start-from-head --query 'events[].message' --output text > "$TMP/reset.log" 2> /dev/null; then
  log "logs del reset:"; tr '\t' '\n' < "$TMP/reset.log"
else
  log "no se pudieron leer los logs del reset (no hace fallar)"
fi
[ "$RESET_EXIT" = "0" ] || falla "reset_baseline.py termino con exit ${RESET_EXIT:-<sin exit>} (stopCode ${RESET_STOP_CODE:-<sin stopCode>}, ${RESET_STOPPED_REASON:-sin stoppedReason})"
log "reset ok ($RESET_SEG s, stopCode $RESET_STOP_CODE)"

# --- Frontend y espera -----------------------------------------------------------------

ETAPA=frontend
MODELO="$MODELO" SLUG="$SLUG" IMAGEN="$FRONTEND_IMAGEN_PROD" SALIDA_JSON="$FRONTEND_JSON" bash "$SCRIPTS_DIR/desplegar-frontend.sh" \
  || falla "desplegar-frontend.sh: $(jq -r '"\(.etapa) - \(.motivo // "sin motivo")"' "$FRONTEND_JSON" 2> /dev/null || echo "sin resultado del script")"

ETAPA=espera
MODELO="$MODELO" SLUG="$SLUG" SALIDA_JSON="$ESPERA_JSON" bash "$SCRIPTS_DIR/esperar-entorno.sh" \
  || falla "esperar-entorno.sh: $(jq -r '.motivo // "sin motivo"' "$ESPERA_JSON" 2> /dev/null || echo "sin resultado del script")"

# --- Marcador de entorno disponible ------------------------------------------------------

ETAPA=marcador
jq -nc --arg modelo "$MODELO" --arg slug "$SLUG" --argjson n "$N" --arg corrida "$CORRIDA" \
  --arg rama "${RAMA:-}" --arg build_id "${CODEBUILD_BUILD_ID:-}" \
  --arg backend "$BACKEND_IMAGEN_PROD" --arg frontend "$FRONTEND_IMAGEN_PROD" --arg tf_version "$TF_VERSION" \
  --arg frontend_hash "$(jq -r '.frontend_hash // empty' "$FRONTEND_JSON")" \
  --arg inicio "$(iso "$INICIO")" --arg creado_at "$(iso "$(ahora)")" \
  'def s: if . == "" then null else . end;
   {modelo: $modelo, slug: $slug, n: $n, corrida: $corrida, rama: ($rama | s), build_id: ($build_id | s),
    imagenes: {backend: $backend, frontend: $frontend}, frontend_hash: ($frontend_hash | s),
    terraform_version: $tf_version, creacion_inicio: $inicio, creado_at: $creado_at}' \
  | aws s3 cp - "s3://$STATES_BUCKET/$MARCADOR_KEY" --content-type application/json --only-show-errors \
  || falla "no se pudo escribir el marcador s3://$STATES_BUCKET/$MARCADOR_KEY"
MARCADOR_URI="s3://$STATES_BUCKET/$MARCADOR_KEY"
log "entorno disponible, marcador $MARCADOR_URI"
