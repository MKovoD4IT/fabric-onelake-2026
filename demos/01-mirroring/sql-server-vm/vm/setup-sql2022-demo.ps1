<#
    Se ejecuta DENTRO de la VM (vía az vm run-command, como el admin local, que es sysadmin).
    Idempotente: se puede volver a correr.

      1. Inicializa el disco de datos (F:) y crea las carpetas de SQL
      2. Descarga y restaura AdventureWorks2022 (OLTP completo) en F:
      3. SQL Server Agent en inicio automático y corriendo (CDC lo necesita)
      4. Autenticación mixta (el login de Fabric es SQL auth vía gateway)
      5. Habilita CDC en la base y en cada tabla con PK
      6. Crea fabric_login con permisos mínimos: CONNECT SQL + CONNECT/SELECT en la base.
         Como CDC ya queda habilitado acá, el login de Fabric NO necesita sysadmin.

    https://learn.microsoft.com/fabric/mirroring/sql-server-tutorial
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory)] [string] $FabricLoginPassword,
    [string] $Database   = 'AdventureWorks2022',
    [string] $BackupUrl  = 'https://github.com/Microsoft/sql-server-samples/releases/download/adventureworks/AdventureWorks2022.bak',
    [string] $DataDrive  = 'F',
    # Run Command con --run-as-user agrega "2>archivo_stderr" como argumento literal: se descarta
    [Parameter(ValueFromRemainingArguments)] [string[]] $IgnoredArgs
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# Run Command con --run-as-user no devuelve stderr: los errores se escriben en la salida estándar
trap {
    Write-Output "ERROR: $($_.Exception.Message)"
    Write-Output "  en: $($_.InvocationInfo.PositionMessage)"
    exit 1
}

function Invoke-Sql([string] $sql, [string] $db = 'master', [hashtable] $params = @{}, [switch] $Scalar) {
    $cn = New-Object System.Data.SqlClient.SqlConnection "Server=.;Database=$db;Integrated Security=SSPI;TrustServerCertificate=True"
    $cn.Open()
    try {
        $cmd = $cn.CreateCommand()
        $cmd.CommandText    = $sql
        $cmd.CommandTimeout = 1800
        foreach ($k in $params.Keys) { [void]$cmd.Parameters.AddWithValue($k, $params[$k]) }
        if ($Scalar) { return $cmd.ExecuteScalar() }
        $da = New-Object System.Data.SqlClient.SqlDataAdapter $cmd
        $dt = New-Object System.Data.DataTable
        [void]$da.Fill($dt)
        return ,$dt
    } finally { $cn.Close() }
}

function Step($msg) { Write-Output "== $msg" }

Step "Contexto"
if ((Invoke-Sql "SELECT IS_SRVROLEMEMBER('sysadmin')" -Scalar) -ne 1) {
    throw "$(whoami) no es sysadmin en SQL Server"
}
Write-Output "Usuario: $(whoami) (sysadmin)"

# 1. Disco de datos ---------------------------------------------------------------
Step "Disco de datos ${DataDrive}:"
if (-not (Get-Volume -DriveLetter $DataDrive -ErrorAction SilentlyContinue)) {
    $disk = Get-Disk | Where-Object { $_.PartitionStyle -eq 'RAW' -and $_.FriendlyName -notmatch 'Direct' } |
            Sort-Object Number | Select-Object -First 1
    if (-not $disk) { throw "No hay disco de datos sin inicializar" }
    Initialize-Disk -Number $disk.Number -PartitionStyle GPT
    New-Partition -DiskNumber $disk.Number -UseMaximumSize -DriveLetter $DataDrive | Out-Null
    Format-Volume -DriveLetter $DataDrive -FileSystem NTFS -AllocationUnitSize 65536 `
                  -NewFileSystemLabel 'SQLData' -Confirm:$false | Out-Null
    Write-Output "Disco $($disk.Number) inicializado como ${DataDrive}: (NTFS 64K)"
} else { Write-Output "Ya existe" }

$dataDir = "${DataDrive}:\SQLData"; $logDir = "${DataDrive}:\SQLLog"; $bakDir = "${DataDrive}:\Backup"
foreach ($d in $dataDir, $logDir, $bakDir) {
    New-Item -ItemType Directory -Force $d | Out-Null
    icacls $d /grant 'NT Service\MSSQLSERVER:(OI)(CI)F' /Q | Out-Null
}

# 2. AdventureWorks2022 -------------------------------------------------------------
Step "Base $Database"
$exists = Invoke-Sql "SELECT COUNT(*) FROM sys.databases WHERE name = @db" -params @{ '@db' = $Database } -Scalar
if ($exists -eq 0) {
    $bak = Join-Path $bakDir 'AdventureWorks2022.bak'
    if (-not (Test-Path $bak)) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $BackupUrl -OutFile $bak -UseBasicParsing
        Write-Output "Backup descargado ($([math]::Round((Get-Item $bak).Length / 1MB)) MB)"
    }
    $files = Invoke-Sql "RESTORE FILELISTONLY FROM DISK = @bak" -params @{ '@bak' = $bak }
    $moves = foreach ($f in $files.Rows) {
        $dir = if ($f.Type -eq 'L') { $logDir } else { $dataDir }
        $ext = if ($f.Type -eq 'L') { '_log.ldf' } else { '.mdf' }
        "MOVE N'$($f.LogicalName)' TO N'$dir\$Database$ext'"
    }
    Invoke-Sql "RESTORE DATABASE [$Database] FROM DISK = @bak WITH $($moves -join ', '), RECOVERY, STATS = 25" `
               -params @{ '@bak' = $bak } | Out-Null
    Write-Output "Restaurada en $dataDir / $logDir"
} else { Write-Output "Ya existe" }

# 3. SQL Server Agent ---------------------------------------------------------------
Step "SQL Server Agent"
Set-Service SQLSERVERAGENT -StartupType Automatic
if ((Get-Service SQLSERVERAGENT).Status -ne 'Running') { Start-Service SQLSERVERAGENT }
Write-Output "Automático y corriendo"

# 4. Autenticación mixta ------------------------------------------------------------
Step "Autenticación mixta"
$instKey = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL').MSSQLSERVER
$regPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instKey\MSSQLServer"
if ((Get-ItemProperty $regPath).LoginMode -ne 2) {
    Set-ItemProperty $regPath -Name LoginMode -Value 2
    Restart-Service MSSQLSERVER -Force
    Start-Service SQLSERVERAGENT
    Write-Output "Habilitada (servicio reiniciado)"
} else { Write-Output "Ya estaba habilitada" }

# 5. CDC ----------------------------------------------------------------------------
Step "CDC en $Database"
Invoke-Sql "IF (SELECT is_cdc_enabled FROM sys.databases WHERE name = DB_NAME()) = 0 EXEC sys.sp_cdc_enable_db;" $Database | Out-Null
$enabled = Invoke-Sql @"
DECLARE @s sysname, @t sysname, @n int = 0;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT s.name, t.name
    FROM sys.tables t JOIN sys.schemas s ON s.schema_id = t.schema_id
    WHERE t.is_ms_shipped = 0 AND t.is_tracked_by_cdc = 0 AND s.name <> 'cdc'
      AND EXISTS (SELECT 1 FROM sys.indexes i WHERE i.object_id = t.object_id AND i.is_primary_key = 1);
OPEN c; FETCH NEXT FROM c INTO @s, @t;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC sys.sp_cdc_enable_table @source_schema = @s, @source_name = @t, @role_name = NULL;
    SET @n += 1;
    FETCH NEXT FROM c INTO @s, @t;
END
SELECT @n;
"@ $Database -Scalar
$summary = Invoke-Sql @"
SELECT SUM(CASE WHEN t.is_tracked_by_cdc = 1 THEN 1 ELSE 0 END) AS con_cdc,
       SUM(CASE WHEN t.is_tracked_by_cdc = 0 THEN 1 ELSE 0 END) AS sin_cdc
FROM sys.tables t JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE t.is_ms_shipped = 0 AND s.name <> 'cdc';
"@ $Database
Write-Output "Tablas habilitadas ahora: $enabled. Total con CDC: $($summary.Rows[0].con_cdc), sin CDC: $($summary.Rows[0].sin_cdc)"
$jobs = Invoke-Sql "SELECT name FROM msdb.dbo.sysjobs WHERE name LIKE 'cdc.' + @db + '%'" -params @{ '@db' = $Database }
Write-Output "Jobs de CDC: $(($jobs.Rows | ForEach-Object name) -join ', ')"

# 6. Login de Fabric ----------------------------------------------------------------
Step "fabric_login"
Invoke-Sql @"
DECLARE @sql nvarchar(max) =
    CASE WHEN SUSER_ID('fabric_login') IS NULL THEN N'CREATE' ELSE N'ALTER' END
    + N' LOGIN [fabric_login] WITH PASSWORD = ' + QUOTENAME(@pw, '''') + N', CHECK_POLICY = ON';
EXEC sys.sp_executesql @sql;
GRANT CONNECT SQL TO [fabric_login];
"@ -params @{ '@pw' = $FabricLoginPassword } | Out-Null
Invoke-Sql @"
IF USER_ID('fabric_user') IS NULL CREATE USER [fabric_user] FOR LOGIN [fabric_login];
GRANT CONNECT, SELECT TO [fabric_user];
"@ $Database | Out-Null
$sa = Invoke-Sql "SELECT IS_SRVROLEMEMBER('sysadmin', 'fabric_login')" -Scalar
Write-Output "fabric_login creado (sysadmin: $sa). Permisos en ${Database}: CONNECT, SELECT"

Step "Listo"
