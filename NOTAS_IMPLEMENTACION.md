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

- El CI no tiene credenciales del cluster: solo abre un PR en el repo GitOps (modelo pull). Para escribir en otro repositorio no alcanza el `GITHUB_TOKEN`, así que se usa un PAT fine-grained (secret `BEYBLADE_TOKEN` en el repo de la app) limitado a `BeybladePeru-gitops`.
- El PR usa una rama fija (`ci/dev-image-tag`). Si llegan dos pushes antes de mergear, el PR se actualiza al último SHA en vez de acumular PRs obsoletos.
- `yq` (preinstalado en `ubuntu-latest`) edita solo el campo `newTag` de cada imagen y conserva los comentarios del archivo.

## 14. Observaciones sobre lo ya hecho (sin cambios aplicados)

- **Node.js 20 llegó a EOL el 30-04-2026.** Los Dockerfiles y el CI usan `node:20-alpine`. Funciona, pero ya no recibe parches de seguridad. Se recomienda subir a Node 22 o 24 LTS en un cambio aparte, que debe pasar por QA.
- ~~`CLOUDINARY_CLOUD_NAME` en `base/backend/configmap.yaml` tiene el valor `CAMBIAR`.~~ Resuelto: ahora tiene el cloud name real, y `BREVO_SENDER_EMAIL` es el remitente verificado en Brevo (ver punto 19).
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
- **Consecuencia.** El secret `BEYBLADE_TOKEN` es un PAT fine-grained de `joacx200222`, limitado a `BeybladePeru-gitops` (Contents y Pull requests: read/write). Se guarda como secret en `lolxd123v2/BeybladePeru`, y para eso hace falta rol **admin** en ese repo: con permiso de escritura no se pueden gestionar secrets. Si el repo GitOps es privado, el PAT de solo lectura de Argo CD también sale de `joacx200222`.

## 19. Servicios externos: Cloudinary y Brevo

- Se crearon cuentas gratuitas. En Cloudinary hay que **generar** la API key (Settings → API Keys); no siempre viene creada. En Brevo, la API key es **Restricted**, con permiso solo de *Transactional email: All* (la app solo envía correos de verificación, recuperación de contraseña y bienvenida).
- Brevo solo envía desde remitentes verificados. El valor anterior, `no-reply@beybladeperu.localhost`, se habría rechazado, así que se reemplazó por un Gmail verificado. Brevo advierte por DKIM/DMARC ("Freemail domain is not recommended"): los correos salen, pero pueden caer en spam. En producción real haría falta un dominio propio autenticado.
- Brevo restringe la API key por IP de origen (*Security → Authorised IPs*). Hay que desactivarlo o autorizar la IP pública desde la que sale el cluster.
- Los secretos se sellaron con una variante no interactiva de `sellar-secretos.ps1`: lee las claves de variables de entorno y usa la misma tubería `kubectl | kubeseal`, así que no queda texto en claro en disco. Las contraseñas de MySQL y el `JWT_SECRET` son distintos por ambiente.
- **Cuidado al rotar claves:** volver a ejecutar el script regenera las contraseñas de MySQL, y un PVC ya inicializado no las acepta (punto 10). Para cambiar solo Cloudinary o Brevo hay que usar `kubeseal --merge-into` sobre el `sealed-secrets.yaml` existente.

## 20. Despliegue real con Argo CD y promoción dev → qa → prod

- El repo GitOps es privado. Argo CD lo lee con un PAT fine-grained de solo lectura (*Contents: Read*) de `joacx200222`, guardado en el Secret `repo-beybladeperu-gitops` (namespace `argocd`, etiqueta `secret-type=repository`). Ese Secret se creó con `kubectl` y **no está en Git**.
- Los overlays de qa y prod apuntaban a `9b41df5`, una imagen que solo existió en local para la prueba de humo y nunca se publicó en GHCR. Por eso las Applications se aplicaron de a una: primero dev, que el CI ya había llevado a `6383a7b` (PR #1). Después qa se promovió por PR (#2) y se validó con `api-tests` (45/45). Por último se promovió prod (#3).
- Las waves funcionaron como se diseñaron. En cada ambiente: MySQL Ready → `prisma-migrate` Complete al **primer intento** → backend → frontend + Ingress → (QA) `api-tests`. Ningún problema del punto 17 se repitió.

## 21. Empate de prioridad de rutas en Traefik

- **Problema.** Con todo en Synced/Healthy, `qa.beybladeperu.localhost/health` devolvía el 404 de Next.js, mientras que en dev y prod respondía el backend. Los manifiestos eran idénticos.
- **Causa.** Traefik convierte cada path del Ingress en una regla y, si no hay prioridad explícita, ordena las reglas por **largo de la regla**. `Path(`/health`)` (pathType `Exact`) y `PathPrefix(`/`)` tienen 15 caracteres cada una y llevan el mismo `Host(...)`, así que empatan y el orden queda indefinido. En dev y prod ganó la regla correcta por azar; en QA, no.
- **Decisión.** `/health` pasa a `pathType: Prefix`. La regla resultante, `PathPrefix(`/health`)`, tiene 21 caracteres y siempre gana a `PathPrefix(`/`)`. El frontend no tiene rutas `/health*`, así que no se pisa nada. `/api` no tenía el problema: `PathPrefix(`/api`)` ya era más larga. Argo CD lo aplicó en los tres ambientes al refrescar.

## 22. PowerShell 5.1 y BOM en los YAML

- `Set-Content -Encoding utf8` agrega un BOM (`EF BB BF`) en Windows PowerShell 5.1. Pasó al editar `envs/qa/kustomization.yaml` para la promoción. Kustomize lo tolera, pero ensucia el diff. Se quitó en un commit aparte, y las ediciones siguientes se hicieron con `sed`.
- Relacionado: el paso de `yq` del CI conserva los comentarios, pero borra las líneas en blanco de `envs/dev/kustomization.yaml`. Es solo estético.

## 23. Versión visible en `/health` (trazabilidad)

- Para comprobar desde fuera qué versión corre en cada ambiente, y para que un rollback se pudiera ver, el CI pasa el SHA del commit como `build-arg APP_VERSION` al backend, y `GET /health` lo devuelve en el campo `version`. El cambio entró con el PR #2 de la app y sirvió como segunda versión real (`2f9b326`) para las demos.

## 24. Corte breve en cada rollout: `preStop`

- **Problema.** Justo después del rollback, `/health` devolvió **504 Gateway Timeout** tras ~30 s. Se midió consultando `/health` cada 0,5 s durante un rolling restart: 1 de 112 peticiones quedó colgada. Al terminar un pod, Kubernetes le envía SIGTERM al mismo tiempo que lo saca de los endpoints, y Traefik sigue enrutando unos instantes a la IP de un pod que ya cerró su puerto.
- **Decisión.** Backend y frontend tienen ahora `lifecycle.preStop: sleep 10`. El pod sigue atendiendo 10 s mientras Traefik retira su endpoint, y recién después recibe SIGTERM. La misma prueba dio **0 de 144** peticiones fallidas.

## 25. El self-heal no ejecuta hooks: migración como initContainer

- **Problema.** En la demo de desastre (borrar `beybladeperu-dev` entero), Argo CD recreó todo por self-heal, **menos el Job `prisma-migrate`**. El auto-sync que dispara el self-heal sobre la misma revisión aplica los recursos normales, pero no ejecuta hooks. El resultado: el backend corría sin tablas (`/api/factions` → "Error en la base de datos") y Argo CD lo marcaba Healthy, porque `/health` no consulta la BD. Hizo falta un sync explícito (25 s) para recuperar el ambiente. La recuperación ante desastre no era automática.
- **Decisión (aprobada).** La migración pasó a ser un **initContainer** del backend (misma imagen, `prisma migrate deploy` en bucle hasta que MySQL responda). Se eliminó `base/migration-job.yaml`. Cualquier pod nuevo del backend migra antes de arrancar, venga de Argo CD, del self-heal o de un `kubectl apply`. Esto también cubre el caso del punto 17. Se mantiene el orden BD → migración → API.
- **Verificación.** Al repetir el borrado del namespace, Argo CD lo recreó en **98 s**, con migración, las 3 facciones, `/health` y `/` en 200, y sin intervención manual. Waves vigentes: -1 SealedSecret, 0 MySQL, 2 backend (con migración), 3 frontend + Ingress, 4 `api-tests` (PostSync, solo QA).
- Detalle: los Jobs `prisma-migrate` de la versión anterior quedaron en qa y prod, porque Argo CD no hace prune de los hooks. Se borraron a mano.
- **Lección para el informe:** que Argo CD marque el ambiente como "Healthy" no asegura que la aplicación funcione. El health check de Kubernetes solo ve lo que miden las probes. Trabajo futuro: un `/health/ready` que consulte la BD.

## 26. Demos y métricas de la implementación

Todas las demos se hicieron en dev, el 27-11-2026 (UTC). Los registros con marcas de tiempo están en los logs de las demos.

| Escenario | Acción | Resultado | Tiempo |
|---|---|---|---|
| Entrega completa de un cambio | Merge del PR #2 de la app → CI → PR automático en GitOps (#4) → merge → Argo CD | dev sirve `version: 2f9b326` | **6 min 28 s** (CI de `main`: 5 min 31 s; GitOps → dev sirviendo: 41 s) |
| Rollback | `git revert` del merge de dev en el repo GitOps | dev vuelve a `6383a7b`, Healthy, `/health` 200 | **23 s** desde el push |
| Restauración | `git revert` del revert | dev vuelve a `2f9b326` | **22 s** desde el push |
| Deriva: réplicas | `kubectl scale deploy/backend --replicas=3` | El self-heal vuelve a 1 réplica | **1-2 s** |
| Deriva: recurso borrado | `kubectl delete svc frontend` | El Service se recrea y `/` vuelve a 200 | **3-5 s** |
| Desastre (antes del punto 25) | `kubectl delete ns beybladeperu-dev` | Recreado **sin migración**; hizo falta un sync manual | 120 s + 25 s manual |
| Desastre (después del punto 25) | `kubectl delete ns beybladeperu-dev` | Recreado completo y funcional, sin intervención | **98 s** |
| Disponibilidad en rollout (antes del punto 24) | Rolling restart con `/health` cada 0,5 s | 1 de 112 fallidas (timeout) | — |
| Disponibilidad en rollout (después del punto 24) | Igual | **0 de 144** fallidas | — |
| Validación automática en QA | PostSync `api-tests` en cada revisión | 45/45 en todas las ejecuciones | ~30 s |

El historial de despliegues que se puede auditar está en dos lugares: `git log` del repo GitOps (quién cambió qué y cuándo) y `status.history` de cada Application de Argo CD (qué revisión se desplegó y cuándo).

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
| CI del PR #1 de la app (build back/front, `prisma-drift`) | OK: 3 jobs en verde; GHCR y el PR a GitOps se omiten en los PR, como corresponde |
| CI de `main` tras el merge (`6383a7b`) | OK: imágenes publicadas en GHCR y PR automático abierto en el repo GitOps con `BEYBLADE_TOKEN` |
| Imágenes de GHCR públicas | OK: el manifest de `backend`, `backend-tests` y `frontend` responde 200 sin credenciales |
| Argo CD: `beybladeperu-dev` | OK: Synced/Healthy en 80 s; imagen de GHCR (`sha256:ca9ecd48…`); facciones inicializadas |
| Argo CD: `beybladeperu-qa` (PostSync `api-tests`) | OK: Synced/Healthy en 150 s; `api-tests` 45/45 |
| Argo CD: `beybladeperu-prod` | OK: Synced/Healthy en 60 s; 1 backend + 2 frontend; PVC de 5Gi |
| Ingress en los 3 hosts (`/health`, `/`, `/api/factions`) | OK: 200 en `dev.`, `qa.` y `beybladeperu.localhost`, después del arreglo del punto 21 |
