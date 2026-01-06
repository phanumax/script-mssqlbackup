<#
.SYNOPSIS
  Provision Backup Cleanup Job (Daily 23:00)
  Owner: sa (runs with sysadmin privileges)

.DESCRIPTION
  This script provisions ONLY the SQL Server cleanup job to remove old backup files.
  - Job Owner: sa (System Administrator) - to allow xp_delete_file execution
  - Schedule: Daily 23:00

.PARAMETER SqlInstance
  SQL Server instance name (e.g., "localhost" or "SERVER\INSTANCE")

.PARAMETER DatabaseName
  Target database name

.PARAMETER BackupFolder
  Backup destination folder

.PARAMETER KeepDays
  Retention period in days (default: 7)

.PARAMETER DryRun
  Test mode - shows SQL commands without executing
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)] [string]$SqlInstance,
    [Parameter(Mandatory=$true)] [string]$DatabaseName,
    [string]$BackupFolder       = "C:\Daily_backup",
    [int]$KeepDays              = 7,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# ---- Utility Functions ----
function Info($m){ Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Warn($m){ Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Success($m){ Write-Host "[SUCCESS] $m" -ForegroundColor Green }
function Error($m){ Write-Host "[ERROR] $m" -ForegroundColor Red }

function Invoke-Tsql {
    param([string]$Server, [string]$Db, [string]$SqlText)
    
    if ($DryRun) { 
        Write-Host "`n--- DRYRUN: $Db ---" -ForegroundColor Yellow
        Write-Host $SqlText -ForegroundColor Gray
        return 
    }
    
    $cmdObj = Get-Command sqlcmd.exe -ErrorAction SilentlyContinue
    if (-not $cmdObj) { 
        throw "sqlcmd.exe not found. Please install SQL Server Command Line Utilities." 
    }

    $tmpFile = [System.IO.Path]::Combine($env:TEMP, "sql_job_cleanup_$([guid]::NewGuid()).sql")
    
    try {
        [System.IO.File]::WriteAllText($tmpFile, $SqlText, [System.Text.Encoding]::UTF8)
        & $cmdObj.Source -S "$Server" -d "$Db" -i "$tmpFile" -b 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { 
            throw "T-SQL Execution failed with exit code $LASTEXITCODE" 
        }
    }
    finally {
        if (Test-Path $tmpFile) {
            Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---- Validation ----
Info "--- Starting Cleanup Job Provisioning for Database: $DatabaseName ---"
Info "SQL Instance: $SqlInstance"
Info "Cleanup Path: $BackupFolder"
Info "Retention: $KeepDays days"

# Note: We use 'sa' as the owner to bypass xp_delete_file permission issues
$owner = "sa" 
Info "Job Owner: $owner"

# ---- [Step 1] Cleanup Job (Daily 23:00) ----
Info "Creating Backup Cleanup job..."

$jobC = "Backup Cleanup (23:00) - $DatabaseName"
$cleanSql = @"
USE [msdb];

-- Create job if not exists
IF NOT EXISTS (SELECT 1 FROM sysjobs WHERE name = N'$jobC')
BEGIN
    EXEC sp_add_job 
        @job_name = N'$jobC', 
        @owner_login_name = N'$owner',
        @description = N'Remove backup files older than $KeepDays days for $DatabaseName',
        @category_name = N'Database Maintenance';
    PRINT 'Created job: $jobC';
END

-- Create job step using xp_delete_file
DECLARE @CCmd nvarchar(max) = N'
DECLARE @OlderThan datetime = DATEADD(day, -$KeepDays, GETDATE());
DECLARE @Path nvarchar(500) = N''$BackupFolder'';

-- Delete .bak files older than retention
EXEC master.dbo.xp_delete_file 
    0,                    -- 0 = backup files
    @Path,
    N''bak'',
    @OlderThan,
    1;                    -- 1 = include subdirectories

-- Delete .dif files older than retention  
EXEC master.dbo.xp_delete_file 
    0,
    @Path,
    N''dif'',
    @OlderThan,
    1;

PRINT ''Cleanup completed for files older than '' + CONVERT(nvarchar(30), @OlderThan, 120);
';

IF NOT EXISTS (SELECT 1 FROM sysjobsteps js JOIN sysjobs j ON j.job_id = js.job_id WHERE j.name = N'$jobC')
BEGIN
    EXEC sp_add_jobstep 
        @job_name = N'$jobC', 
        @step_name = N'Purge Old Backups', 
        @subsystem = N'TSQL',
        @database_name = N'master',
        @command = @CCmd,
        @on_success_action = 1,
        @on_fail_action = 2,
        @retry_attempts = 1,
        @retry_interval = 5;
    PRINT 'Created job step: Purge Old Backups';
END

-- Create schedule: Daily 23:00
IF NOT EXISTS (SELECT 1 FROM sysschedules WHERE name = N'Daily2300')
BEGIN
    EXEC sp_add_schedule 
        @schedule_name = N'Daily2300', 
        @freq_type = 4,              -- Daily
        @freq_interval = 1,          -- Every 1 day
        @active_start_time = 230000; -- 23:00:00
    PRINT 'Created schedule: Daily2300';
END

-- Attach schedule to job
IF NOT EXISTS (SELECT 1 FROM sysjobschedules js 
    JOIN sysjobs j ON j.job_id = js.job_id 
    JOIN sysschedules s ON s.schedule_id = js.schedule_id
    WHERE j.name = N'$jobC' AND s.name = N'Daily2300')
BEGIN
    EXEC sp_attach_schedule @job_name = N'$jobC', @schedule_name = N'Daily2300';
    PRINT 'Attached schedule to job';
END

-- Add job to server
IF NOT EXISTS (SELECT 1 FROM sysjobservers js JOIN sysjobs j ON j.job_id = js.job_id WHERE j.name = N'$jobC')
BEGIN
    EXEC sp_add_jobserver @job_name = N'$jobC', @server_name = N'$AgentServerName';
    PRINT 'Added job to server';
END
"@

try {
    Invoke-Tsql -Server $SqlInstance -Db "msdb" -SqlText $cleanSql
    Success "Backup Cleanup job created"
}
catch {
    Error "Failed to create Cleanup job: $_"
    throw
}

# ---- Summary ----
Write-Host "`n========================================" -ForegroundColor Green
Success "Cleanup Job Provisioned Successfully!"
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Info "Job Created:"
Write-Host "  1. $jobC" -ForegroundColor Cyan
Write-Host ""
Warn "Note: This job is owned by 'sa' to authorize cleanup."
Write-Host ""
