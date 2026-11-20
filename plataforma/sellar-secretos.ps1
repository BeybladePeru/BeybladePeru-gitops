<#
  Genera envs/<ambiente>/sealed-secrets.yaml con el Secret "beybladeperu-secrets"
  (7 claves) cifrado para el namespace beybladeperu-<ambiente>.

  - Los valores en claro solo viven en memoria: se piden por consola (ocultos) o
    se generan al azar; nunca se escriben a disco ni se imprimen.
  - Requiere el cluster arriba y el controlador de Sealed Secrets instalado
    (kubeseal descarga su certificado publico desde kube-system).

  Uso (desde la raiz de BeybladePeru-gitops):
    .\plataforma\sellar-secretos.ps1 -Ambiente dev
    .\plataforma\sellar-secretos.ps1 -Ambiente qa -ConCredencialesDeTest
#>
param(
  [Parameter(Mandatory)] [ValidateSet('dev', 'qa', 'prod')] [string] $Ambiente,
  # Solo QA: sella tambien "beybladeperu-test-credentials" para el Job de tests
  [switch] $ConCredencialesDeTest
)
$ErrorActionPreference = 'Stop'
$ns = "beybladeperu-$Ambiente"
$salida = Join-Path $PSScriptRoot "..\envs\$Ambiente\sealed-secrets.yaml"

function Leer-Secreto([string] $nombre) {
  $s = Read-Host "$nombre ($Ambiente)" -AsSecureString
  $v = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
         [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))
  if ([string]::IsNullOrWhiteSpace($v)) { throw "$nombre no puede estar vacio" }
  return $v
}
# Aleatorio solo con [A-Za-z0-9]: no hace falta escaparlo dentro de DATABASE_URL
function Nuevo-Aleatorio([int] $largo) {
  $abc = [char[]]'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
  $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
  $b = New-Object byte[] $largo; $rng.GetBytes($b)
  -join ($b | ForEach-Object { $abc[$_ % $abc.Length] })
}
function Sellar([string] $nombreSecret, [hashtable] $datos) {
  $kargs = @('create', 'secret', 'generic', $nombreSecret, '-n', $ns, '--dry-run=client', '-o', 'yaml')
  foreach ($k in $datos.Keys) { $kargs += "--from-literal=$k=$($datos[$k])" }
  # kubectl -> kubeseal por tuberia: el Secret en claro nunca toca el disco
  & kubectl @kargs | & kubeseal --format yaml --controller-namespace kube-system --controller-name sealed-secrets-controller
  if ($LASTEXITCODE -ne 0) { throw "kubeseal fallo para $nombreSecret" }
}

# Generadas: no hace falta conocerlas, solo que sean consistentes entre si
$mysqlPassword = Nuevo-Aleatorio 32
$datos = @{
  MYSQL_PASSWORD        = $mysqlPassword
  MYSQL_ROOT_PASSWORD   = Nuevo-Aleatorio 32
  JWT_SECRET            = Nuevo-Aleatorio 64
  # Debe coincidir con base/mysql/statefulset.yaml (usuario beyblade, BD beybladeperu)
  DATABASE_URL          = "mysql://beyblade:$mysqlPassword@mysql:3306/beybladeperu"
  # De servicios externos: se piden por consola
  CLOUDINARY_API_KEY    = Leer-Secreto 'CLOUDINARY_API_KEY'
  CLOUDINARY_API_SECRET = Leer-Secreto 'CLOUDINARY_API_SECRET'
  BREVO_API_KEY         = Leer-Secreto 'BREVO_API_KEY'
}

$yaml = @(Sellar 'beybladeperu-secrets' $datos)
if ($ConCredencialesDeTest) {
  if ($Ambiente -ne 'qa') { throw '-ConCredencialesDeTest solo aplica a qa' }
  $yaml += '---'
  $yaml += Sellar 'beybladeperu-test-credentials' @{
    TEST_EMAIL          = Leer-Secreto 'TEST_EMAIL'
    TEST_PASSWORD       = Leer-Secreto 'TEST_PASSWORD'
    TEST_ADMIN_EMAIL    = Leer-Secreto 'TEST_ADMIN_EMAIL'
    TEST_ADMIN_PASSWORD = Leer-Secreto 'TEST_ADMIN_PASSWORD'
  }
}
# UTF-8 sin BOM (Out-File -Encoding utf8 de PowerShell 5.1 agrega BOM)
[IO.File]::WriteAllLines([IO.Path]::GetFullPath($salida), [string[]]$yaml, (New-Object Text.UTF8Encoding $false))
Write-Host "OK -> $salida (cifrado para $ns; se puede commitear)"
