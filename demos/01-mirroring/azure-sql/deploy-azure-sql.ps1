<#
.SYNOPSIS
    Crea la fuente Azure SQL Database (AdventureWorksLT) para la Demo 1 de Mirroring.

.DESCRIPTION
    - Resource group
    - Servidor lógico de Azure SQL con:
        * System Assigned Managed Identity (requisito de Mirroring para escribir en OneLake)
        * Autenticación solo Microsoft Entra, con el usuario actual de az CLI como admin
        * TLS 1.2 mínimo
    - Firewall: "Allow Azure services" (para que Fabric se conecte) + IP pública del cliente
    - Base AdventureWorksLT desde el sample oficial, en vCore General Purpose
      (los tiers DTU Basic/Standard por debajo de 100 DTU no soportan Mirroring)

    Requiere: az CLI con sesión iniciada en el mismo tenant de Entra que Fabric.

.EXAMPLE
    ./deploy-azure-sql.ps1 -Location centralus -ResourceGroup rg-dev-centus-mk
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Location,
    [string] $ResourceGroup = 'rg-fabric-onelake-demo',
    [string] $ServerName    = "sql-onelake-demo-$((Get-Random -Maximum 99999).ToString('00000'))",
    [string] $DatabaseName  = 'AdventureWorksLT',

    # Serverless: cobra por segundo de uso. Provisioned: cobra fijo por hora.
    [ValidateSet('Serverless', 'Provisioned')]
    [string] $ComputeModel  = 'Serverless',
    [int]    $VCores        = 2,
    [double] $MinVCores     = 0.5,
    # Minutos sin actividad antes de pausar (solo Serverless). -1 = nunca pausar.
    [int]    $AutoPauseDelay = 60
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

function Invoke-Az {
    $out = & az @args
    if ($LASTEXITCODE -ne 0) { throw "az $($args -join ' ') falló (exit $LASTEXITCODE)" }
    return $out
}

Write-Host "== Cuenta de Azure" -ForegroundColor Cyan
$account = Invoke-Az account show -o json | ConvertFrom-Json
Write-Host "Suscripción: $($account.name) ($($account.id))"
Write-Host "Tenant:      $($account.tenantId)"

$me = Invoke-Az ad signed-in-user show -o json | ConvertFrom-Json
Write-Host "Admin Entra: $($me.userPrincipalName)"

Write-Host "== Proveedor Microsoft.Sql" -ForegroundColor Cyan
if ((Invoke-Az provider show -n Microsoft.Sql --query registrationState -o tsv) -ne 'Registered') {
    Write-Host "Registrando (puede tardar unos minutos)..."
    Invoke-Az provider register -n Microsoft.Sql --wait -o none
}
Write-Host "Registrado."

Write-Host "== Resource group $ResourceGroup ($Location)" -ForegroundColor Cyan
if ((Invoke-Az group exists -n $ResourceGroup) -eq 'true') {
    # No se modifica un RG existente (az group create reemplazaría sus tags)
    Write-Host "Ya existe; se usa tal cual."
} else {
    Invoke-Az group create -n $ResourceGroup -l $Location `
        --tags proyecto=fabric-onelake-2026 demo=01-mirroring -o none
}

Write-Host "== Servidor lógico $ServerName" -ForegroundColor Cyan
Invoke-Az sql server create -g $ResourceGroup -n $ServerName -l $Location `
    --assign-identity `
    --enable-ad-only-auth `
    --external-admin-principal-type User `
    --external-admin-name $me.userPrincipalName `
    --external-admin-sid $me.id `
    --minimal-tls-version 1.2 `
    -o none

Write-Host "== Firewall" -ForegroundColor Cyan
# 0.0.0.0 - 0.0.0.0 = "Allow Azure services and resources to access this server"
Invoke-Az sql server firewall-rule create -g $ResourceGroup -s $ServerName `
    -n AllowAzureServices --start-ip-address 0.0.0.0 --end-ip-address 0.0.0.0 -o none

$myIp = (Invoke-RestMethod -Uri 'https://api.ipify.org').Trim()
Invoke-Az sql server firewall-rule create -g $ResourceGroup -s $ServerName `
    -n "Client-$($env:COMPUTERNAME)" --start-ip-address $myIp --end-ip-address $myIp -o none
Write-Host "IP cliente permitida: $myIp"

Write-Host "== Base $DatabaseName (sample AdventureWorksLT, $ComputeModel)" -ForegroundColor Cyan
$dbArgs = @(
    'sql', 'db', 'create', '-g', $ResourceGroup, '-s', $ServerName, '-n', $DatabaseName,
    '--sample-name', 'AdventureWorksLT',
    '--edition', 'GeneralPurpose', '--family', 'Gen5', '--capacity', $VCores,
    '--compute-model', $ComputeModel,
    '--backup-storage-redundancy', 'Local',
    '--max-size', '32GB',
    '-o', 'none'
)
if ($ComputeModel -eq 'Serverless') {
    $dbArgs += @('--min-capacity', $MinVCores, '--auto-pause-delay', $AutoPauseDelay)
}
Invoke-Az @dbArgs

$fqdn = "$ServerName.database.windows.net"
Write-Host ""
Write-Host "Listo." -ForegroundColor Green
Write-Host "Servidor: $fqdn"
Write-Host "Base:     $DatabaseName"
Write-Host ""
Write-Host "Validar qué se espeja:"
Write-Host "  sqlcmd -S $fqdn -d $DatabaseName --authentication-method ActiveDirectoryDefault -i ..\sql\validate-mirroring-eligibility.sql"
Write-Host "Verificar que la SAMI es la identidad primaria:"
Write-Host "  sqlcmd -S $fqdn -d $DatabaseName --authentication-method ActiveDirectoryDefault -Q `"SELECT identity_type, is_primary FROM sys.dm_server_managed_identities`""
