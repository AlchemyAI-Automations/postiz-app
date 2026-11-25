#!/usr/bin/env bash
# Guarda el App ID y el App secret de la app de Meta en el compose de Postiz
# sin que pasen por un chat ni por el historial de la terminal, y recrea la app.
#
# Uso, desde tu terminal:  ssh -t alchemyai /home/alchemyai/Postiz/set-meta-app.sh
set -euo pipefail
cd "$(dirname "$0")"

read -rp 'App ID de Meta: ' APP_ID
read -rsp 'App secret de Meta (no se muestra): ' APP_SECRET
echo
[[ "$APP_ID" =~ ^[0-9]{8,20}$ ]] || { echo 'El App ID son solo numeros.'; exit 1; }
[[ "$APP_SECRET" =~ ^[0-9a-f]{32}$ ]] || { echo 'El App secret son 32 caracteres hexadecimales.'; exit 1; }

cp -p docker-compose.yaml "docker-compose.yaml.bak-$(date -u +%Y%m%d-%H%M%S)-meta"
APP_ID="$APP_ID" APP_SECRET="$APP_SECRET" python3 - <<'EOF'
import os, re
p = 'docker-compose.yaml'
s = open(p).read()
for key, env in (('FACEBOOK_APP_ID', 'APP_ID'), ('FACEBOOK_APP_SECRET', 'APP_SECRET')):
    s, n = re.subn(r'(\n\s+' + key + r': )"[^"]*"', lambda m: m.group(1) + '"' + os.environ[env] + '"', s)
    if n != 1:
        raise SystemExit(f'No encontre {key} en docker-compose.yaml')
open(p, 'w').write(s)
EOF
unset APP_SECRET

docker compose up -d postiz
for i in $(seq 1 60); do
  if [ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:4007/api/auth/can-register || true)" = "200" ]; then
    if docker inspect postiz-app -f '{{range .Config.Env}}{{println .}}{{end}}' | grep -qE '^FACEBOOK_APP_ID=[0-9]+$'; then
      echo 'Listo: Postiz ya tiene la app de Meta. Conecta Facebook Page o Instagram (Facebook Business).'
      exit 0
    fi
  fi
  sleep 5
done
echo 'Postiz no respondio en 300 s; revisa: docker logs postiz-app'
exit 1
