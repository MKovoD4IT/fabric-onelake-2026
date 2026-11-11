<#
.SYNOPSIS
    Prepara SQL Server 2022 en la VM para la Demo 1: disco de datos, AdventureWorks2022,
    SQL Agent, autenticación mixta, CDC y el login de Fabric con permisos mínimos.

.DESCRIPTION
    Ejecuta vm/setup-sql2022-demo.ps1 dentro de la VM con Run Command, como el admin local
    (que es sysadmin en SQL Server). No hace falta RDP.

    Contraseñas (fuera del repo):
      %USERPROFILE%\.fabric-onelake\<VmName>.txt              admin de la VM (lo genera deploy-sql2022-vm.ps1)
      %USERPROFILE%\.fabric-onelake\fabric_login-<VmName>.txt login de Fabric (se genera acá)

    El password de fabric_login viaja como parámetro protegido de Run Command
    (no queda visible en la definición del recurso).
#>
[CmdletBinding()]
param(
    [string] $ResourceGroup = 'rg-dev-centus-mk',
    [string] $VmName        = 'vmsql22dev01',
    [string] $AdminUser     = 'vmsql22dev01admin'
)

$ErrorActionPreference = 'Stop'

function Read-Secret([string] $file) {
    ((Get-Content $file) | Where-Object { $_ -like 'Password:*' }) -replace '^Password:\s*', ''
}

# Solo letras, dígitos y '_': evita problemas de quoting en az.cmd (que hace eco del comando si falla el parseo)
function New-SafePassword([int] $length = 24) {
    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789'
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    $b = [byte[]]::new($length); $rng.GetBytes($b)
    (-join ($b | ForEach-Object { $chars[$_ % $chars.Length] })) + 'Aa9_'
}

$secretDir  = Join-Path $env:USERPROFILE '.fabric-onelake'
$adminPw    = Read-Secret (Join-Path $secretDir "$VmName.txt")
$fabricFile = Join-Path $secretDir "fabric_login-$VmName.txt"
if (-not (Test-Path $fabricFile)) {
    @("Servidor: $VmName (vía gateway)", 'Usuario:  fabric_login', "Password: $(New-SafePassword)") |
        Set-Content -Encoding utf8 $fabricFile
    Write-Host "Contraseña de fabric_login generada en $fabricFile"
}
$fabricPw = Read-Secret $fabricFile

$vmScript = Join-Path $PSScriptRoot 'vm\setup-sql2022-demo.ps1'
$rcName   = 'setup-sql2022-demo'

Write-Host "== Ejecutando en $VmName (puede tardar varios minutos)" -ForegroundColor Cyan
& az vm run-command create -g $ResourceGroup --vm-name $VmName --name $rcName `
    --script "@$vmScript" `
    --run-as-user $AdminUser --run-as-password $adminPw `
    --protected-parameters "FabricLoginPassword=$fabricPw" `
    --timeout-in-seconds 3600 -o none 2>$null
$createExit = $LASTEXITCODE

$view = & az vm run-command show -g $ResourceGroup --vm-name $VmName --name $rcName --instance-view `
    --query "instanceView" -o json | ConvertFrom-Json
& az vm run-command delete -g $ResourceGroup --vm-name $VmName --name $rcName --yes -o none

Write-Host $view.output
if ($view.error) { Write-Host $view.error -ForegroundColor Red }
if ($createExit -ne 0 -or $view.executionState -ne 'Succeeded' -or $view.exitCode -ne 0) {
    throw "Run Command terminó en estado $($view.executionState) (exit $($view.exitCode))"
}
Write-Host "Listo." -ForegroundColor Green
