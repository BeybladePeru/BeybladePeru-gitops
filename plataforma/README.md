# Plataforma: k3d + Argo CD + Sealed Secrets

Comandos en PowerShell, desde la raíz de `BeybladePeru-gitops`. Versiones fijadas:

| Componente | Versión |
|---|---|
| k3d / k3s | v5.9.0 / v1.35.5-k3s1 |
| Argo CD | v3.6.1 |
| Sealed Secrets (controlador y kubeseal) | v0.41.2 |

Requisitos: Docker Desktop corriendo, `kubectl`, `k3d` y `kubeseal` en el PATH.

## 1. Cluster

```powershell
k3d cluster create --config plataforma/k3d-config.yaml
kubectl get nodes                       # 1 server + 2 agents en Ready
kubectl -n kube-system get pods -l app.kubernetes.io/name=traefik   # Ingress Controller de k3s
```

`*.localhost` resuelve a 127.0.0.1 en Chrome, Edge, Firefox y curl, así que no hace falta editar `hosts`.

## 2. Sealed Secrets (controlador)

```powershell
kubectl apply -f https://github.com/bitnami/sealed-secrets/releases/download/v0.41.2/controller.yaml
kubectl -n kube-system rollout status deploy/sealed-secrets-controller
kubeseal --fetch-cert > $env:TEMP\sealed-secrets.pem   # prueba de conectividad (el cert es público)
```

**Respaldo de la clave privada.** Si el cluster se borra, los `sealed-secrets.yaml` de Git ya no se pueden descifrar. Guarda la clave **fuera de Git**:

```powershell
kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > $HOME\sealed-secrets-key.BACKUP.yaml
# Restaurar en un cluster nuevo, ANTES de instalar el controlador:
# kubectl apply -f $HOME\sealed-secrets-key.BACKUP.yaml
```

## 3. Argo CD

Argo CD 3.x necesita `--server-side`: algunos CRD superan el límite de 256 KB de la anotación `last-applied-configuration`.

```powershell
kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.6.1/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-server
# Contraseña inicial del usuario admin
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | ForEach-Object { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_)) }
# UI en https://localhost:8080
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

**Si `BeybladePeru-gitops` es privado**, registra el repo con un PAT de solo lectura. El Secret se crea a mano y no va a Git:

```powershell
kubectl -n argocd create secret generic repo-beybladeperu-gitops `
  --from-literal=type=git `
  --from-literal=url=https://github.com/joacx200222/BeybladePeru-gitops.git `
  --from-literal=username=joacx200222 `
  --from-literal=password=<PAT_CONTENTS_READ>
kubectl -n argocd label secret repo-beybladeperu-gitops argocd.argoproj.io/secret-type=repository
```

## 4. Secretos por ambiente

Cada namespace tiene su propio Secret `beybladeperu-secrets` con 7 claves. Kubeseal usa scope *strict* por defecto: el cifrado queda atado al nombre **y** al namespace, así que un SealedSecret de dev no sirve en prod.

### Opción A: script (recomendada)

Genera al azar `MYSQL_PASSWORD`, `MYSQL_ROOT_PASSWORD` y `JWT_SECRET`, arma `DATABASE_URL` a partir de ellos y pide por consola (con entrada oculta) las claves de Cloudinary y Brevo. Los valores en claro nunca se guardan en disco.

```powershell
.\plataforma\sellar-secretos.ps1 -Ambiente dev
.\plataforma\sellar-secretos.ps1 -Ambiente qa              # agrega -ConCredencialesDeTest para los tests de auth
.\plataforma\sellar-secretos.ps1 -Ambiente prod
```

### Opción B: comandos manuales

Reemplaza cada `CAMBIAR_*`. Repite con `-n beybladeperu-qa` / `envs/qa` y con `-n beybladeperu-prod` / `envs/prod`.

```powershell
kubectl create secret generic beybladeperu-secrets -n beybladeperu-dev --dry-run=client -o yaml `
  --from-literal=MYSQL_PASSWORD=CAMBIAR_MYSQL_PASSWORD `
  --from-literal=MYSQL_ROOT_PASSWORD=CAMBIAR_MYSQL_ROOT_PASSWORD `
  --from-literal=DATABASE_URL="mysql://beyblade:CAMBIAR_MYSQL_PASSWORD@mysql:3306/beybladeperu" `
  --from-literal=JWT_SECRET=CAMBIAR_JWT_SECRET `
  --from-literal=CLOUDINARY_API_KEY=CAMBIAR_CLOUDINARY_API_KEY `
  --from-literal=CLOUDINARY_API_SECRET=CAMBIAR_CLOUDINARY_API_SECRET `
  --from-literal=BREVO_API_KEY=CAMBIAR_BREVO_API_KEY |
  kubeseal --format yaml > envs/dev/sealed-secrets.yaml
```

- `DATABASE_URL` tiene que llevar **la misma** contraseña que `MYSQL_PASSWORD`. Si la contraseña tiene caracteres como `@ : / ? #`, hay que codificarlos para URL.
- MySQL solo lee `MYSQL_PASSWORD` y `MYSQL_ROOT_PASSWORD` la primera vez que arranca con el volumen vacío. Si cambias la contraseña después, tienes que cambiarla también dentro de MySQL (`ALTER USER`) o borrar el PVC `data-mysql-0`, lo que borra los datos.
- `CLOUDINARY_CLOUD_NAME` no es secreto: está en `base/backend/configmap.yaml` con el valor `CAMBIAR`. Pon ahí tu cloud name real.

## 5. Imágenes de GHCR

Si los paquetes `beybladeperu-backend`, `beybladeperu-backend-tests` y `beybladeperu-frontend` son **públicos** (GitHub → Packages → Package settings → Change visibility), no se necesita nada más. Si son privados, crea un pull secret en cada namespace y asígnalo a la ServiceAccount `default`:

```powershell
foreach ($ns in 'beybladeperu-dev','beybladeperu-qa','beybladeperu-prod') {
  kubectl create namespace $ns --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n $ns create secret docker-registry ghcr-pull --docker-server=ghcr.io --docker-username=lolxd123v2 --docker-password=<PAT_READ_PACKAGES>
  kubectl -n $ns patch serviceaccount default -p '{\"imagePullSecrets\":[{\"name\":\"ghcr-pull\"}]}'
}
```

## 6. Aplicaciones (app of apps)

`plataforma/root-app.yaml` es la unica Application que se aplica a mano. Gestiona todo `apps/`:
la Application de plataforma (Sealed Secrets, wave -1) y los tres ambientes (waves 0, 1 y 2).
Desde ese momento, agregar o cambiar una Application tambien es un PR.

```powershell
kubectl apply -f plataforma/root-app.yaml
kubectl -n argocd get applications -w
```

### Antes (instalacion inicial, sin app raiz)

```powershell
# Primero hay que commitear y pushear envs/*/sealed-secrets.yaml a main
kubectl apply -f apps/
kubectl -n argocd get applications -w
```

Comprobación:

```powershell
curl.exe -s http://dev.beybladeperu.localhost/health
curl.exe -s -o NUL -w "%{http_code}`n" http://dev.beybladeperu.localhost/
kubectl -n beybladeperu-qa logs job/api-tests        # resultado de la suite en QA
```

## Promoción entre ambientes

dev se actualiza solo: el CI abre un PR y tú lo mergeas. Para pasar a qa y prod, abre un PR que copie el mismo SHA en `envs/qa/kustomization.yaml` (los 3 tags) y luego en `envs/prod/kustomization.yaml`. La imagen es la misma en los tres ambientes; solo cambian el overlay y el Secret.
