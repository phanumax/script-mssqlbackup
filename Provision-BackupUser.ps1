<#
.SYNOPSIS
  Provisions the SQL Backup Service Account and assigns necessary roles.
  
.DESCRIPTION
  Creates a login '[MachineName]\sqlbackup' if it doesn't exist.
  Assigns 'SQLAgentUserRole' in msdb.
  Assigns 'db_backupoperator' in the target database.

.PARAMETER SqlInstance
  SQL Server instance name (e.g., "localhost" or "SERVER\INSTANCE")

.PARAMETER DatabaseName
  Target database name to assign backup permissions.

.PARAMETER DryRun
  Test mode - shows SQL commands without executing.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)] [string]$SqlInstance,
    [Parameter(Mandatory=$true)] [string]$DatabaseName,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

function Info($m){ Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Success($m){ Write-Host "[SUCCESS] $m" -ForegroundColor Green }
function Error($m){ Write-Host "[ERROR] $m" -ForegroundColor Red }

function Invoke-Tsql {
    param([string]$Server, [string]$SqlText)
    
    if ($DryRun) { 
        Write-Host "`n--- DRYRUN ---" -ForegroundColor Yellow
        Write-Host $SqlText -ForegroundColor Gray
        return 
    }
    
    $cmdObj = Get-Command sqlcmd.exe -ErrorAction SilentlyContinue
    if (-not $cmdObj) { 
        throw "sqlcmd.exe not found. Please install SQL Server Command Line Utilities." 
    }

    $tmpFile = [System.IO.Path]::Combine($env:TEMP, "sql_user_provision_$([guid]::NewGuid()).sql")
    
    try {
        [System.IO.File]::WriteAllText($tmpFile, $SqlText, [System.Text.Encoding]::UTF8)
        & $cmdObj.Source -S "$Server" -i "$tmpFile" -b 2>&1 | Out-Null
        
        if ($LASTEXITCODE -ne 0) { 
            throw "T-SQL Execution failed with exit code $LASTEXITCODE" 
        }
    }
    finally {
        if (Test-Path $tmpFile) { Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue }
    }
}

Info "--- Provisioning Backup User for: $DatabaseName ---"

$sql = @"
SET NOCOUNT ON;

DECLARE @Host sysname = CAST(SERVERPROPERTY('MachineName') AS sysname);
DECLARE @LoginName sysname = @Host + N'\sqlbackup';
DECLARE @DbName sysname = N'$DatabaseName';

PRINT 'Target Login: ' + @LoginName;

-- 1) Create LOGIN (if missing)
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = @LoginName)
BEGIN
    DECLARE @CreateLoginSql nvarchar(max) = 'CREATE LOGIN [' + @LoginName + '] FROM WINDOWS;';
    EXEC(@CreateLoginSql);
    PRINT 'Created Login: ' + @LoginName;
END
ELSE
BEGIN
    PRINT 'Login already exists.';
END

-- 2) Assign SQLAgentUserRole in msdb
USE msdb;
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = @LoginName)
BEGIN
    DECLARE @CreateUserMsdbSql nvarchar(max) = 'CREATE USER [' + @LoginName + '] FOR LOGIN [' + @LoginName + '];';
    EXEC(@CreateUserMsdbSql);
    PRINT 'Created User in msdb.';
END

IF IS_ROLEMEMBER('SQLAgentUserRole', @LoginName) = 0
BEGIN
    EXEC sp_addrolemember N'SQLAgentUserRole', @LoginName;
    PRINT 'Assigned SQLAgentUserRole in msdb.';
END

-- 3) Assign db_backupoperator in Target DB
DECLARE @DynamicSql nvarchar(max) = N'
USE ' + QUOTENAME(@DbName) + N';

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = ''' + REPLACE(@LoginName,'''','''''') + N''')
BEGIN
    CREATE USER [' + @LoginName + N'] FOR LOGIN [' + @LoginName + N'];
    PRINT ''Created User in target database.'';
END

IF IS_ROLEMEMBER(''db_backupoperator'', ''' + REPLACE(@LoginName,'''','''''') + N''') = 0
BEGIN
    EXEC sp_addrolemember N''db_backupoperator'', ''' + REPLACE(@LoginName,'''','''''') + N''';
    PRINT ''Assigned db_backupoperator in target database.'';
END
';

EXEC(@DynamicSql);
"@

try {
    Invoke-Tsql -Server $SqlInstance -SqlText $sql
    Success "User Provisioning Completed Successfully!"
}
catch {
    Error "Failed to provision user: $_"
    throw
}
