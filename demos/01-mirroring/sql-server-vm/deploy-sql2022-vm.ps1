<#
.SYNOPSIS
    Crea la VM con SQL Server 2022 Developer para la Demo 1 (Mirroring de SQL Server vía CDC + gateway).

.DESCRIPTION
    Mismo sizing que la VM existente con SQL Server 2025 (vmsqldev01), pero con discos Standard SSD:
      - Standard_D4ads_v6 (4 vCPU, 16 GB, AMD, disco temporal NVMe), Trusted Launch
        (vmsqldev01 usa D4ads_v7; la cuota de esa familia en Central US es de 4 vCPU y ya está usada)
      - Imagen MicrosoftSQLServer:sql2022-ws2022:sqldev-gen2 (SQL Server 2022 Developer)
      - Disco de SO Standard SSD 127 GB + disco de datos Standard SSD 16 GB (ReadOnly cache)
      - Misma VNet/subnet que vmsqldev01; NSG propio con RDP solo desde la IP del cliente
      - IP pública Standard estática
      - Apagado automático 22:00 (Romance Standard Time) con aviso por mail 30 min antes
      - Registro en la extensión SQL IaaS (licencia PAYG: Developer no tiene costo de licencia)

    Por qué SQL Server 2022 y no 2025: el mirroring de SQL Server 2025 no está soportado en Azure VM.

    La contraseña del administrador se genera y se guarda FUERA del repo, en
    %USERPROFILE%\.fabric-onelake\<VmName>.txt

.EXAMPLE
    ./deploy-sql2022-vm.ps1
#>
[CmdletBinding()]
param(
    [string] $ResourceGroup = 'rg-dev-centus-mk',
    [string] $Location      = 'centralus',
    [string] $VmName        = 'vmsql22dev01',
    [string] $AdminUser     = 'vmsql22dev01admin',
    [string] $VmSize        = 'Standard_D4ads_v6',
    [string] $Image         = 'MicrosoftSQLServer:sql2022-ws2022:sqldev-gen2:latest',
    [string] $VnetName      = 'vmsqldev01-vnet',
    [string] $SubnetName    = 'default',
    [int]    $OsDiskGb      = 127,
    [int]    $DataDiskGb    = 16,
    [string] $DiskSku       = 'StandardSSD_LRS',
    [string] $ShutdownTime  = '2200',
    [string] $ShutdownTz    = 'Romance Standard Time',
    [string] $NotifyEmail   = ''
)

$ErrorActionPreference = 'Stop'

function Invoke-Az {
    $out = & az @args
    if ($LASTEXITCODE -ne 0) {
        # No mostrar la contraseña en el mensaje de error
        $shown = for ($i = 0; $i -lt $args.Count; $i++) {
            if ($i -gt 0 -and $args[$i - 1] -eq '--admin-password') { '***' } else { $args[$i] }
        }
        throw "az $($shown -join ' ') falló (exit $LASTEXITCODE)"
    }
    return $out
}

function New-StrongPassword([int] $length = 24) {
    $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnpqrstuvwxyz', '23456789', '!@#%^*-_=+')
    $rng  = [Security.Cryptography.RandomNumberGenerator]::Create()
    $pick = {
        param($s)
        $b = [byte[]]::new(4); $rng.GetBytes($b)
        $s[[BitConverter]::ToUInt32($b, 0) % $s.Length]
    }
    $chars = foreach ($s in $sets) { & $pick $s }                      # uno de cada tipo
    $all   = -join $sets
    $chars += 1..($length - $sets.Count) | ForEach-Object { & $pick $all }
    -join ($chars | Sort-Object { [Guid]::NewGuid() })
}

Write-Host "== Cuenta de Azure" -ForegroundColor Cyan
$account = Invoke-Az account show -o json | ConvertFrom-Json
Write-Host "Suscripción: $($account.name)"
if (-not $NotifyEmail) { $NotifyEmail = $account.user.name }

Write-Host "== Credenciales" -ForegroundColor Cyan
$secretDir  = Join-Path $env:USERPROFILE '.fabric-onelake'
$secretFile = Join-Path $secretDir "$VmName.txt"
New-Item -ItemType Directory -Force $secretDir | Out-Null
if (Test-Path $secretFile) {
    $password = (Get-Content $secretFile | Where-Object { $_ -like 'Password:*' }) -replace '^Password:\s*', ''
    Write-Host "Se reutiliza la contraseña de $secretFile"
} else {
    $password = New-StrongPassword
    @("VM:       $VmName", "Usuario:  $AdminUser", "Password: $password") | Set-Content -Encoding utf8 $secretFile
    Write-Host "Contraseña generada y guardada en $secretFile"
}

Write-Host "== NSG $VmName-nsg (RDP solo desde la IP del cliente)" -ForegroundColor Cyan
$myIp = (Invoke-RestMethod -Uri 'https://api.ipify.org').Trim()
Invoke-Az network nsg create -g $ResourceGroup -n "$VmName-nsg" -l $Location -o none
Invoke-Az network nsg rule create -g $ResourceGroup --nsg-name "$VmName-nsg" -n RDP-Cliente `
    --priority 300 --access Allow --protocol Tcp --direction Inbound `
    --source-address-prefixes "$myIp/32" --destination-port-ranges 3389 -o none
Write-Host "RDP permitido desde $myIp"

Write-Host "== VM $VmName ($VmSize, $Image)" -ForegroundColor Cyan
$subnetId = Invoke-Az network vnet subnet show -g $ResourceGroup --vnet-name $VnetName -n $SubnetName --query id -o tsv
Invoke-Az vm create -g $ResourceGroup -n $VmName -l $Location `
    --image $Image `
    --size $VmSize `
    --admin-username $AdminUser --admin-password $password `
    --computer-name $VmName `
    --security-type TrustedLaunch --enable-secure-boot true --enable-vtpm true `
    --disk-controller-type NVMe `
    --os-disk-name "$VmName-osdisk" --os-disk-size-gb $OsDiskGb --storage-sku $DiskSku `
    --os-disk-caching ReadWrite `
    --data-disk-sizes-gb $DataDiskGb --data-disk-caching ReadOnly `
    --subnet $subnetId `
    --nsg "$VmName-nsg" `
    --public-ip-address "$VmName-ip" --public-ip-sku Standard --public-ip-address-allocation static `
    -o none

# Boot diagnostics con storage administrado, igual que vmsqldev01
Invoke-Az vm boot-diagnostics enable -g $ResourceGroup -n $VmName -o none

Write-Host "== Apagado automático $ShutdownTime ($ShutdownTz)" -ForegroundColor Cyan
$vmId = Invoke-Az vm show -g $ResourceGroup -n $VmName --query id -o tsv
$schedule = @{
    location   = $Location
    properties = @{
        status               = 'Enabled'
        taskType             = 'ComputeVmShutdownTask'
        dailyRecurrence      = @{ time = $ShutdownTime }
        timeZoneId           = $ShutdownTz
        targetResourceId     = $vmId
        notificationSettings = @{
            status = 'Enabled'; timeInMinutes = 30; emailRecipient = $NotifyEmail; notificationLocale = 'en'
        }
    }
} | ConvertTo-Json -Depth 5 -Compress
$schedFile = New-TemporaryFile
Set-Content -Encoding ascii $schedFile $schedule
Invoke-Az resource create -g $ResourceGroup -n "shutdown-computevm-$VmName" `
    --resource-type Microsoft.DevTestLab/schedules --is-full-object --properties "@$schedFile" -o none
Remove-Item $schedFile

Write-Host "== Extensión SQL IaaS" -ForegroundColor Cyan
Invoke-Az sql vm create -g $ResourceGroup -n $VmName -l $Location `
    --license-type PAYG --sql-mgmt-type Full -o none

$ip = Invoke-Az vm show -g $ResourceGroup -n $VmName -d --query publicIps -o tsv
Write-Host ""
Write-Host "Listo." -ForegroundColor Green
Write-Host "VM:          $VmName ($ip)"
Write-Host "Usuario:     $AdminUser"
Write-Host "Credenciales en $secretFile"
Write-Host "RDP:         mstsc /v:$ip"
