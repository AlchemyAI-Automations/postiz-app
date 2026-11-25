#!/usr/bin/env bash
# Despliegue de Postiz (fork AlchemyAI) en el VPS. Ver ALCHEMYAI.md.
#
# Uso, en /home/alchemyai/Postiz:
#   ./deploy.sh              descarga :latest y lo levanta
#   ./deploy.sh <sha>        despliega una imagen concreta (ghcr ...:<sha>)
#   FORCE=1 ./deploy.sh      despliega aunque haya posts vencidos en cola
# Rollback: ./deploy.sh rollback-<AAAAMMDD-HHMMSS>  (imagen local postiz-app:rollback-*)
set -euo pipefail

cd "$(dirname "$0")"
IMG=ghcr.io/alchemyai-automations/postiz-app
TARGET=${1:-latest}
STAMP=$(date -u +%Y%m%d-%H%M%S)
DB=alchemyai-db
log() { printf '[deploy %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
psql_postiz() { docker exec "$DB" psql -U alchemyai -d postiz -At -c "$1"; }

# 1. Respaldo de la base
mkdir -p backups
docker exec "$DB" pg_dump -U alchemyai -d postiz --no-owner | gzip > "backups/postiz-db-$STAMP.sql.gz"
chmod 600 "backups/postiz-db-$STAMP.sql.gz"
log "respaldo: backups/postiz-db-$STAMP.sql.gz"

# 2. Imagen actual etiquetada para rollback
current=$(docker inspect postiz-app -f '{{.Image}}' 2>/dev/null || true)
if [ -n "$current" ]; then
  docker tag "$current" "postiz-app:rollback-$STAMP"
  log "rollback disponible: ./deploy.sh rollback-$STAMP"
fi

# 3. Posts vencidos en cola: al arrancar el worker saldrian todos de golpe
overdue=$(psql_postiz "SELECT count(*) FROM \"Post\" WHERE \"deletedAt\" IS NULL AND state='QUEUE' AND \"publishDate\" < now() - interval '5 minutes';")
if [ "$overdue" != "0" ] && [ "${FORCE:-0}" != "1" ]; then
  log "ALTO: $overdue posts vencidos en cola. Reprogramalos o cancelalos (ver incident_postiz_temporal_worker_race) o corre con FORCE=1."
  exit 1
fi

# 4. Imagen nueva (compose usa :latest)
# (comandos sueltos: dentro de una cadena && un fallo no detiene set -e)
case "$TARGET" in
  rollback-*)
    docker tag "postiz-app:$TARGET" "$IMG:latest"
    ;;
  latest)
    docker pull --quiet "$IMG:latest"
    ;;
  *)
    docker pull --quiet "$IMG:$TARGET"
    docker tag "$IMG:$TARGET" "$IMG:latest"
    ;;
esac
want=$(docker image inspect "$IMG:latest" -f '{{.Id}}')
log "imagen: ${want:7:12}"

# 5. Dependencias primero; la app espera a que Temporal responda (race de julio 2026)
docker compose up -d postiz-redis temporal-elasticsearch postiz-temporal
for i in $(seq 1 36); do
  if docker exec postiz-temporal sh -c 'temporal operator cluster health --address $(hostname -i):7233' 2>/dev/null | grep -q SERVING; then
    log "temporal SERVING"
    break
  fi
  [ "$i" = 36 ] && { log "temporal no responde tras 180 s"; exit 1; }
  sleep 5
done

# 6. App (comprueba que el contenedor corre la imagen pedida, no la anterior)
docker compose up -d postiz
running=$(docker inspect postiz-app -f '{{.Image}}')
if [ "$running" != "$want" ]; then
  log "postiz-app corre ${running:7:12}, se esperaba ${want:7:12}"
  exit 1
fi
for i in $(seq 1 60); do
  code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:4007/api/auth/can-register || true)
  if [ "$code" = "200" ]; then
    log "API 200. Desplegado."
    exit 0
  fi
  if docker logs --since "$((i * 5 + 30))s" postiz-app 2>&1 | grep -q 'accept-data-loss'; then
    log "prisma db push se detuvo por una advertencia de perdida de datos:"
    docker logs postiz-app 2>&1 | grep -A6 'There might be data loss' | grep -v 'postgresql://' | head -12
    log "Revisala; si es inofensiva, aplicala una vez y vuelve a correr ./deploy.sh (ver ALCHEMYAI.md)."
    exit 2
  fi
  sleep 5
done
log "la API no respondio en 300 s; revisa: docker logs postiz-app"
exit 1
