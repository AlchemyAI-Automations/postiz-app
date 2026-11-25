# Fork de AlchemyAI

Este repositorio es un fork de [gitroomhq/postiz-app](https://github.com/gitroomhq/postiz-app). La instancia corre en `https://social.alchemyai.tech`, en el VPS de AlchemyAI, en `/home/alchemyai/Postiz`.

## Modificaciones propias

Al sincronizar con upstream hay que conservarlas todas.

| Archivo | Cambio | Motivo |
|---|---|---|
| `libraries/nestjs-libraries/src/integrations/integration.manager.ts` | Redes que no se usan, comentadas. Las nuevas de upstream también entran comentadas. | Cada provider arranca un worker de Temporal. |
| `libraries/nestjs-libraries/src/integrations/social.abstract.ts` | Logs `[AlchemyAI]` del error crudo de cada red, pasados por `redactSecrets`. | Diagnóstico. Meta manda `access_token` en la URL. |
| `libraries/nestjs-libraries/src/integrations/social/linkedin*.provider.ts` | Sin scopes de organización y con `prompt=consent`. | OAuth de perfil personal. |
| `libraries/nestjs-libraries/src/integrations/social/x.provider.ts` | `encodeImageForX`: el formato de la imagen coincide con `media_type`. | Upstream convierte todo a GIF y declara jpeg, y X lo rechaza. |
| `apps/frontend/src/app/colors.scss`, `new-layout/logo.tsx`, `public/alchemyai-icon.svg`, `launches.component.tsx` | Paleta oscura e ícono de AlchemyAI, sin versión en el pie. | Marca. |
| `package.json` → `pnpm.overrides` (entradas a partir de `follow-redirects@1`) y versión de `@sentry/*` | Parches de seguridad sin cambiar de versión mayor. | Ver la sección de seguridad. |
| `.github/workflows/alchemyai-*.yml` | Build de la imagen y vigilancia semanal de upstream. | Solo existen en este fork. |

En el fork están desactivados estos workflows de upstream (`gh workflow disable`): Build Containers, Build Extension, Publish Extension, Deploy to AWS, Issue Label Triggers y Resolve staging conflicts.

## Sincronizar con upstream

1. Cada lunes, el workflow `alchemyai-upstream-watch.yml` hace un merge de prueba (no sube nada) y abre o actualiza el issue «Upstream pending». El issue trae los commits nuevos, los archivos en conflicto, los avisos de seguridad de la semana y el resultado de `pnpm audit`. El merge real se hace a mano porque `GITHUB_TOKEN` no puede subir cambios de upstream a `.github/workflows`.
2. Para hacerlo a mano:
   ```
   git fetch upstream
   git switch -c sync/upstream-AAAAMMDD origin/main
   git merge upstream/main
   ```
   Al resolver un conflicto, conserva el cambio de upstream y vuelve a aplicar la modificación de la tabla.
3. Si hay conflicto en `pnpm-lock.yaml`, toma el de upstream y regenera el lockfile con las overrides:
   ```
   git checkout --theirs pnpm-lock.yaml
   pnpm install --lockfile-only --ignore-scripts
   ```
4. Mergea el PR con **merge commit**, nunca con squash. El squash borra la relación con la historia de upstream y la siguiente sincronización vuelve a chocar en todo.

## Seguridad

- Antes de desplegar, revisa los avisos de Postiz:
  ```
  gh api repos/gitroomhq/postiz-app/security-advisories
  ```
- Revisa también las dependencias:
  ```
  pnpm audit --prod
  ```
  Solo se parchan con overrides las versiones dentro de la misma versión mayor. Las que exigen subir de mayor se dejan a upstream.
- Riesgo residual aceptado el 2026-11-25:

  | Paquete | Dónde se usa | Por qué no es crítico |
  |---|---|---|
  | `zod` 3 | Validación de los SDK de IA | No recibe entrada de usuarios anónimos |
  | `graphql-scalars` 1 | CopilotKit | Ruta con login |
  | `decode-uri-component` 0.2 | `query-string` de WalletConnect | Solo corre en el navegador |
  | `node-forge` | `google-p12-pem` | Solo lee llaves propias |
  | `request` y `tough-cookie` | — | Están abandonados; no hay versión corregida |

- La alerta crítica de `@sentry/nextjs` solo aplica si se usa `tunnelRoute`, y aquí no se usa. Aun así se actualizó.

## Desplegar

El build de `main` publica `ghcr.io/alchemyai-automations/postiz-app:latest` y `:<sha>`. El script versionado es `alchemyai/deploy.sh` y se copia al VPS como `/home/alchemyai/Postiz/deploy.sh`.

```
./deploy.sh                    # :latest
./deploy.sh <sha>              # una imagen concreta
./deploy.sh rollback-<stamp>   # volver a la imagen anterior
```

Con el rollback, `prisma db push` intentará quitar las columnas nuevas y se detendrá por la advertencia de pérdida de datos. En ese caso hay que restaurar el respaldo de la base de ese despliegue.

El script hace esto, en orden:
1. Respalda la base.
2. Etiqueta la imagen actual para poder hacer rollback.
3. Se detiene si hay posts vencidos en cola.
4. Descarga la imagen nueva y levanta Temporal antes que la app.
5. Verifica la API.

Si `prisma db push` se detiene por una advertencia de pérdida de datos, el script la muestra y no la acepta solo.
