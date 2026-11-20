# Notas de implementación (Fase 2)

Dificultades reales encontradas al implementar la migración de BeybladePeru a GitOps y la decisión que se tomó en cada caso. Sirven de insumo para la sección 3.f del informe técnico.

Fecha de inicio: 2026-11-15.

---

## 1. Herramientas ausentes en la estación de trabajo

- **Problema.** La máquina Windows 11 tenía instalados solo `node`, `npm` y `gh`. Faltaban `docker`, `kubectl`, `k3d` y `kubeseal`, así que no se podía ejecutar ninguna de las verificaciones (`docker build`, `kubectl kustomize`, MySQL temporal).
- **Decisión.** Se instalaron `kubectl` 1.37.2 y `k3d` 5.9.0 con `winget`, a nivel de usuario. `kubeseal` no existe en winget, así que se descargó el binario oficial (v0.41.2) desde el release de GitHub. Docker Desktop se instala aparte porque requiere administrador, WSL2 y reinicio. No se instaló `kustomize` por separado: `kubectl kustomize` lo trae embebido (v5.8.1).
- **Consecuencia.** Mientras Docker no estuvo disponible, los builds se verificaron de forma nativa, ejecutando los mismos `npm ci` + `prisma generate` + `npm run build` de los Dockerfiles en una copia aislada del código. `kubectl kustomize` sí se pudo ejecutar desde el inicio.

## 2. Migración inicial de Prisma sin base de datos disponible

- **Problema.** El repositorio no tenía `migrations/`: el esquema se había aplicado siempre con `db push`. Sin migraciones, `prisma migrate deploy` (el Job de la wave 1) no puede crear las tablas. El plan original era ejecutar `prisma migrate dev` contra un MySQL 8.4 temporal en Docker, pero Docker no estaba instalado.
- **Decisión.** La migración `init` se generó con `prisma migrate diff --from-empty --to-schema-datamodel ... --script`. Es el mismo motor de diff que usa `migrate dev` cuando la BD está vacía, y no toca ninguna base de datos existente. El resultado son 16 `CREATE TABLE`, uno por cada `model` del schema, más `migration_lock.toml` con `provider = "mysql"`.
- **Mitigación.** El CI incluye el job `prisma-drift`: aplica las migraciones a un MySQL 8.4 efímero (service container de Actions) y ejecuta `prisma migrate diff --from-url --to-schema-datamodel --exit-code`. Si las migraciones no reproducen el schema exacto, el pipeline falla antes de publicar imágenes. Esto también detecta en el futuro cambios al schema que se hagan sin crear su migración.
- **Riesgo para las BD existentes.** Las BD que hoy se crearon con `db push` no tienen la tabla `_prisma_migrations`. Si se les aplica `migrate deploy` directamente, intentará crear tablas que ya existen. Para adoptarlas hay que marcar la migración como aplicada: `prisma migrate resolve --applied <carpeta>_init`. En el cluster esto no aplica, porque cada ambiente arranca con un PVC vacío.

## 3. Checksums de migración y finales de línea (CRLF)

- **Problema.** Prisma guarda en `_prisma_migrations` un checksum de cada `migration.sql`. En Windows, con `core.autocrlf=true`, el archivo local puede tener CRLF mientras la imagen (construida en Linux) tiene LF. Si alguien ejecuta `migrate` desde Windows contra una BD migrada desde la imagen, aparece un falso "migration was modified".
- **Decisión.** Se añadió a `.gitattributes` la regla `back/database/prisma/migrations/**/*.sql text eol=lf`.

## 4. Lint del frontend con deuda previa

- **Problema.** `npm run lint` falla hoy con 114 errores y 90 warnings. Los errores son 96 de `no-explicit-any`, 12 de `react/no-unescaped-entities` y otros 6. Un lint bloqueante dejaría el CI en rojo desde el primer commit.
- **Decisión.** El paso de lint se ejecuta y queda visible en cada run, pero lleva `continue-on-error: true`. Corregir 114 errores del código de la aplicación queda fuera del alcance de la migración de infraestructura. Cuando se salde la deuda, basta con quitar esa línea para que el lint pase a ser un *quality gate* real.

## 5. Imagen de tests desde el mismo Dockerfile

- **Problema.** La suite `tests/run-tests.ts` necesita `tsx`, que es devDependency, pero la imagen `runner` usa `--omit=dev`. Además, `.dockerignore` excluía `tests/`.
- **Decisión.** Se creó un target `test` que reutiliza la etapa `deps` (ya trae `tsx` y `dotenv`) y copia solo `tests/`. La suite es autocontenida (solo usa `fetch` y `dotenv`), así que no necesita `src/`. Se sacó `tests` del `.dockerignore`; el `runner` sigue sin copiarlo porque solo hace `COPY` explícitos.
- **Detalle importante.** Si no se pasa `--target`, `docker build` construye la **última** etapa. Por eso el target `test` va *antes* de `runner`: un build por defecto sigue produciendo la imagen de la API, y la decisión "una sola imagen para API y migración" se mantiene intacta.
- Se publica como imagen aparte, `ghcr.io/lolxd123v2/beybladeperu-backend-tests:<SHA>`, con el mismo SHA que el backend.

## 6. Credenciales de los tests en QA

- **Problema.** Los tests de autenticación necesitan `TEST_EMAIL`, `TEST_PASSWORD`, `TEST_ADMIN_EMAIL` y `TEST_ADMIN_PASSWORD`. La decisión 4 fija un único Secret con 7 claves, y estas no están entre ellas.
- **Decisión.** No se tocó el Secret de 7 claves. El Job `api-tests` lee un Secret aparte, `beybladeperu-test-credentials`, con `optional: true`. Si no existe, la suite salta los tests de auth y ejecuta igual los de health, ranking y los de rechazo sin token. Se puede sellar con `sellar-secretos.ps1 -Ambiente qa -ConCredencialesDeTest`.
- `backoffLimit: 0`: un test que falla es un resultado, no un error transitorio. Reintentarlo solo retrasaría la señal.

## 7. El backend no escala horizontalmente (prod = 1 réplica)

- **Problema.** El backend tiene estado dentro del proceso:
  - `node-cron` (`src/jobs/faction-season.job.ts`) programa un job diario con zona horaria America/Lima. Con N réplicas se ejecutaría N veces.
  - El rate limiting (`src/middlewares/rate-limit.middleware.ts`) guarda los contadores en un `Map` en memoria. Con N réplicas, el límite efectivo sería N veces el configurado.
- **Decisión.** El backend queda en `replicas: 1` en los tres ambientes, documentado en `envs/prod/patch-recursos.yaml`. El frontend, que no tiene estado, sí corre con 2 réplicas en prod.
- **Riesgo residual.** Durante un rolling update hay unos segundos con dos pods vivos (por `maxSurge` del Deployment). Si el rollout coincidiera exactamente con la hora del cron, este podría ejecutarse dos veces. Se aceptó para no tener downtime en cada despliegue (la alternativa era `strategy: Recreate`).
- **Trabajo futuro para escalar.** Mover el cron a un `CronJob` de Kubernetes, con la misma imagen y un entrypoint dedicado, y el rate limit a un almacén compartido (Redis o MySQL).
- **Observación relacionada.** Express no tiene `trust proxy` configurado. Detrás de Traefik, `req.ip` es la IP del pod de Traefik, no la del cliente. La clave del rate limit incluye `userId`, así que el impacto es acotado, pero conviene `app.set("trust proxy", 1)`.

## 8. Mismo origen para el frontend (`NEXT_PUBLIC_API_URL=/`)

- **Riesgo revisado.** Con `baseURL: "/"`, una ruta como `"/api/x"` podría terminar en `//api/x`, que el navegador interpreta como *host* `api`.
- **Verificación.** axios normaliza la unión de `baseURL` y la ruta (`combineURLs` elimina las barras duplicadas), y todas las llamadas usan rutas como `api.post("/api/...")`. El resultado es `/api/...` relativo al host. No hizo falta cambiar código. El build de Next con `NEXT_PUBLIC_API_URL=/` compiló sin errores.

## 9. Orden de sincronización del Secret

- **Problema.** El SealedSecret que genera kubeseal no trae anotación de wave, así que caía en la wave 0 junto con MySQL. El primer pod de MySQL podía arrancar antes de que el controlador descifrara el Secret y quedar en `CreateContainerConfigError` (se recupera solo, pero ensucia el sync).
- **Decisión.** Cada overlay aplica un parche con `target: kind: SealedSecret` que agrega `argocd.argoproj.io/sync-wave: "-1"`. Así el parche cubre cualquier SealedSecret, incluido el de credenciales de test, sin editar a mano el archivo generado por kubeseal. Argo CD trae health check nativo para SealedSecret, así que espera a que esté descifrado antes de pasar a la wave 0.

## 10. Sealed Secrets: scope, rotación y respaldo

- Con scope *strict* (el valor por defecto), el cifrado queda atado a nombre + namespace. Por eso se genera un `sealed-secrets.yaml` por ambiente, y uno de dev no se puede copiar a prod.
- MySQL solo lee `MYSQL_PASSWORD` y `MYSQL_ROOT_PASSWORD` al inicializar un volumen vacío. Rotarlos en el Secret no cambia la contraseña real: hay que ejecutar `ALTER USER` o recrear el PVC.
- `DATABASE_URL` repite la contraseña de MySQL. El script `sellar-secretos.ps1` genera contraseñas con caracteres `[A-Za-z0-9]` para no tener que codificarlas para URL, y arma `DATABASE_URL` a partir de la misma variable para que nunca diverjan.
- Si se pierde la clave privada del controlador (por ejemplo, al borrar el cluster k3d), los SealedSecret de Git ya no se pueden descifrar. Hay que respaldarla fuera de Git; los comandos están en `plataforma/README.md`.

## 11. Argo CD 3.x y CRDs grandes

- **Problema.** `kubectl apply -f install.yaml` (client-side) falla en Argo CD 3.x porque algunos CRD superan los 256 KB permitidos en la anotación `last-applied-configuration`.
- **Decisión.** Se instala con `kubectl apply --server-side --force-conflicts`.

## 12. StatefulSet: `volumeClaimTemplates` es inmutable

- Prod necesita más disco (5Gi) que dev y qa (1Gi). Ese campo no se puede modificar después de crear el StatefulSet: Argo CD reportaría un error de sync. Por eso el tamaño se fija en el overlay desde el primer despliegue. Cambiarlo más adelante exige borrar el StatefulSet con `--cascade=orphan` y redimensionar el PVC a mano.

## 13. Actualización de dev desde el CI

- El CI no tiene credenciales del cluster: solo abre un PR en el repo GitOps (modelo pull). Para escribir en otro repositorio no alcanza el `GITHUB_TOKEN`, así que se usa un PAT fine-grained (`GITOPS_TOKEN`) limitado a `BeybladePeru-gitops`.
- El PR usa una rama fija (`ci/dev-image-tag`). Si llegan dos pushes antes de mergear, el PR se actualiza al último SHA en vez de acumular PRs obsoletos.
- `yq` (preinstalado en `ubuntu-latest`) edita solo el campo `newTag` de cada imagen y conserva los comentarios del archivo.

## 14. Observaciones sobre lo ya hecho (sin cambios aplicados)

- **Node.js 20 llegó a EOL el 30-04-2026.** Los Dockerfiles y el CI usan `node:20-alpine`. Funciona, pero ya no recibe parches de seguridad. Se recomienda subir a Node 22 o 24 LTS en un cambio aparte, que debe pasar por QA.
- `CLOUDINARY_CLOUD_NAME` en `base/backend/configmap.yaml` tiene el valor `CAMBIAR`; hay que poner el valor real.
- `EMAIL_LOGO_URL` no está en el ConfigMap. El backend usa como fallback `via.placeholder.com`. Conviene definirlo con una URL pública: un logo servido desde `*.localhost` no se ve en los clientes de correo.

## 15. Estación con Docker: WSL2 y memoria

- **Problema.** La segunda máquina tampoco tenía WSL2 ni Docker Desktop. El primer `winget install Docker.DockerDesktop` falló (exit 4) por correr sin elevación. Además tiene **24 GB** de RAM y 16 hilos, no 32 GB como se había supuesto.
- **Decisión.** `wsl --install --no-distribution` y Docker Desktop (29.9.3) instalados con elevación. Se creó `%USERPROFILE%\.wslconfig` con `memory=12GB`, `processors=8`, `swap=4GB` y `autoMemoryReclaim=gradual`. La plataforma completa (k3d, Argo CD, Sealed Secrets y los tres ambientes) pide ~6-8 GB, así que 12 GB deja margen para los builds sin quitarle memoria a Windows. Los `requests`/`limits` de los manifiestos no se tocaron: modelan cada ambiente, no la máquina.

## 16. El backend exige `BREVO_SENDER_EMAIL` al cargar

- `src/config/brevo.config.ts` lanza una excepción en el `import` si falta `BREVO_SENDER_EMAIL`, y el proceso termina con exit 1 antes de abrir el puerto. El ConfigMap base ya la define, así que en el cluster no afecta. Al levantar la imagen a mano (`docker run`) hay que pasar todas las variables del ConfigMap.

## 17. Prueba de humo sin Argo CD: no hay waves ni hooks

- **Problema.** `kubectl apply -k` crea todo a la vez. MySQL tardó ~90 s en inicializar el volumen vacío y:
  1. El Job `prisma-migrate` agotó `backoffLimit: 4` y quedó en `Failed`. Con `restartPolicy: OnFailure`, el último reintento alcanzó a aplicar la migración (`_prisma_migrations` registra `finished_at`) mientras el controlador ya borraba el pod. El Job decía "fallido", la BD estaba migrada y los logs se perdieron con el pod.
  2. El backend arrancó sin BD: `initializeSystem()` captura el error de `initializeFactions()` y sigue. `/health` respondía 200, pero no había facciones y 3 tests de QA fallaron (39/42).
- **Decisión.** No se cambió nada en los manifiestos. Con Argo CD, la wave 0 espera a que MySQL esté Ready, la 1 a que termine la migración y la 2 levanta el backend, así que ninguno de los dos casos ocurre. En la prueba se recrearon los Jobs (como hace `BeforeHookCreation`) y se reinició el backend: QA pasó 45/45.
- **Cambios aplicados después de la prueba (aprobados).**
  - `base/migration-job.yaml`: `restartPolicy: Never` (antes `OnFailure`). Cada reintento es un pod nuevo, se conservan los logs de los fallidos y `backoffLimit` no corta un intento en curso. `api-tests` ya usaba `Never`.
  - `back/src/config/initializer.ts`: `initializeSystem()` reintenta con backoff exponencial (2 s → 30 s máx.) hasta que el seed funciona, en vez de rendirse al primer error. Es seguro porque `initializeFactions()` hace `upsert`. Efecto lateral aceptado: `initializeJobs()` (el cron) se agenda recién cuando la BD responde, lo que de todos modos necesita.
  - Verificado: con el backend arrancado sin BD y MySQL levantado después, registra los intentos 1-4, luego "Facciones inicializadas", y la suite pasa completa.

## 18. Repos en cuentas distintas

- **Decisión.** El repo de la app sigue en `lolxd123v2/BeybladePeru`, y el repo GitOps se crea en `joacx200222/BeybladePeru-gitops`. La cuenta `joacx200222` también tiene acceso al repo de la app.
- **Qué cambió.** El `repoURL` de `apps/app-*.yaml`, el `repository` del checkout en `ci.yml` y el usuario del Secret de repositorio de Argo CD en `plataforma/README.md`.
- **Qué no cambió.** Las imágenes siguen en `ghcr.io/lolxd123v2/...`: el `GITHUB_TOKEN` del CI solo puede publicar paquetes en la cuenta dueña del repo de la app.
- **Consecuencia.** `GITOPS_TOKEN` es un PAT fine-grained de `joacx200222`, limitado a `BeybladePeru-gitops` (Contents y Pull requests: read/write). Se guarda como secret en `lolxd123v2/BeybladePeru`, y para eso hace falta rol **admin** en ese repo: con permiso de escritura no se pueden gestionar secrets. Si el repo GitOps es privado, el PAT de solo lectura de Argo CD también sale de `joacx200222`.

---

## Verificaciones ejecutadas

| Verificación | Resultado |
|---|---|
| `npm ci && prisma generate && npm run build` (back, copia aislada) | OK: `dist/src/index.js` |
| `npm ci && npm run build` con `NEXT_PUBLIC_API_URL=/` (front) | OK: `.next/standalone/server.js`, 35 rutas |
| `npm run lint` (front) | Falla: 114 errores y 90 warnings preexistentes (ver punto 4) |
| `kubectl kustomize base` | OK: 9 recursos |
| `kubectl kustomize envs/{dev,qa,prod}` (con un SealedSecret ficticio) | OK: namespace, host, tags, réplicas, volumen y wave -1 correctos |
| Sintaxis YAML (workflow y manifiestos) | OK |
| `docker build` back (runner y test) y front | OK: `bp-back` 472 MB, `bp-back-tests` 571 MB, `bp-front` 301 MB |
| Migración contra MySQL 8.4 temporal (puerto 3399) | OK: `migrate deploy` aplica `20261115225045_init`; `migrate diff --exit-code` → "No difference detected" (exit 0) |
| `bp-back` contra ese MySQL + `GET /health` | OK: HTTP 200 (con las variables del ConfigMap y secretos ficticios) |
| Imagen `bp-back-tests` contra ese backend | OK: 45/45 |
| Cluster k3d (`plataforma/k3d-config.yaml`) | OK: 1 server + 2 agents Ready, k3s v1.35.5 |
| Sealed Secrets v0.41.2 + Argo CD v3.6.1 (`--server-side`) | OK: controlador y 7 pods de Argo CD Running; `kubeseal --fetch-cert` responde |
| `kubectl apply --dry-run=server` de `envs/{dev,qa,prod}` (SealedSecret descartable sellado con el cert del cluster) | OK: 10 recursos en dev/prod, 11 en qa (`api-tests`) |
| `kubectl apply --dry-run=server -f apps/` | OK: 3 Applications (solo un warning informativo por el nombre del finalizer de Argo CD) |
| Prueba de humo dev + qa sin GHCR (`k3d image import` con el SHA de los overlays, `kubectl apply -k`) | OK tras recrear los hooks a mano (ver punto 17): migración aplicada, `/health` y `/` → 200 por Ingress en `dev.` y `qa.beybladeperu.localhost`, Job `api-tests` en QA 45/45 |
