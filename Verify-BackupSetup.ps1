<#
.SYNOPSIS
  Verifies the SQL Backup Solution configuration.
  
.DESCRIPTION
  Checks:
  1. User Roles (SQLAgentUserRole, db_backupoperator)
  2. Recovery Model (SIMPLE)
  3. Jobs (Existence, Status, Owner)
  4. Log File Size

.PARAMETER SqlInstance
  SQL Server instance name.

.PARAMETER DatabaseName
  Target database name to verify.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)] [string]$SqlInstance,
    [Parameter(Mandatory=$true)] [string]$DatabaseName
)

$ErrorActionPreference = "Stop"

function Info($m){ Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Success($m){ Write-Host "   [PASS] $m" -ForegroundColor Green }
function Fail($m){ Write-Host "   [FAIL] $m" -ForegroundColor Red }

Info "--- Starting Verification for: $DatabaseName ---"

$cmdObj = Get-Command sqlcmd.exe -ErrorAction SilentlyContinue
if (-not $cmdObj) { throw "sqlcmd.exe not found." }

$sql = @"
SET NOCOUNT ON;
DECLARE @DbName sysname = N'$DatabaseName';
DECLARE @Host sysname = CAST(SERVERPROPERTY('MachineName') AS sysname);
DECLARE @LoginName sysname = @Host + N'\sqlbackup';

PRINT 'Checking Configuration...';
PRINT '';

-- 1. Check Roles
USE msdb;
IF IS_ROLEMEMBER('SQLAgentUserRole', @LoginName) = 1
    PRINT 'CHECK|Role_MSDB|PASS|Has SQLAgentUserRole';
ELSE
    PRINT 'CHECK|Role_MSDB|FAIL|Missing SQLAgentUserRole';

DECLARE @DynamicSql nvarchar(max) = N'
USE ' + QUOTENAME(@DbName) + N';
IF IS_ROLEMEMBER(''db_backupoperator'', ''' + REPLACE(@LoginName,'''','''''') + N''') = 1
    PRINT ''CHECK|Role_TargetDB|PASS|Has db_backupoperator''
ELSE
    PRINT ''CHECK|Role_TargetDB|FAIL|Missing db_backupoperator'';

-- 2. Check Recovery Model
SELECT ''CHECK|RecoveryModel|'' + 
       CASE WHEN recovery_model_desc = ''SIMPLE'' THEN ''PASS'' ELSE ''FAIL'' END + 
       ''|'' + recovery_model_desc
FROM sys.databases WHERE name = ''' + @DbName + N''';

-- 3. Check Log File Size
SELECT ''CHECK|LogFileSize|INFO|'' + name + '' = '' + CAST(CAST(size/128.0 AS decimal(10,2)) AS varchar) + '' MB''
FROM sys.master_files WHERE database_id = DB_ID(''' + @DbName + N''') AND type_desc = ''LOG'';
';

EXEC(@DynamicSql);

-- 4. Check Jobs
USE msdb;
SELECT 'CHECK|Job|INFO|' + name + ' (Enabled: ' + CAST(enabled as varchar) + ', Owner: ' + suser_sname(owner_sid) + ')'
FROM sysjobs 
WHERE name LIKE '%' + @DbName + '%'
ORDER BY name;
"@

$tmpFile = [System.IO.Path]::Combine($env:TEMP, "sql_verify_$([guid]::NewGuid()).sql")
try {
    [System.IO.File]::WriteAllText($tmpFile, $sql, [System.Text.Encoding]::UTF8)
    $results = & $cmdObj.Source -S "$SqlInstance" -i "$tmpFile" -b -y 0 2>&1
    
    # Simple Parse output
    $results | ForEach-Object {
        if ($_ -match "^CHECK\|(.*?)\|(.*?)\|(.*)") {
            $checkName = $matches[1]
            $status = $matches[2]
            $detail = $matches[3]
            
            if ($status -eq "PASS") { Success "$checkName : $detail" }
            elseif ($status -eq "FAIL") { Fail "$checkName : $detail" }
            else { Write-Host "   [$status] $checkName : $detail" -ForegroundColor Gray }
        }
    }
}
finally {
    if (Test-Path $tmpFile) { Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue }
}
