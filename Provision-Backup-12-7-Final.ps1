<#
.SYNOPSIS
  Provision Weekly Full (Sun 21:00) + 12h Differential (09:00 Daily, 21:00 Mon-Sat)
  Strategy: 12/7 Balanced (RPO 12h, Retention 7 days)

.DESCRIPTION
  This script provisions SQL Server backup jobs with the following strategy:
  - Full Backup: Sunday 21:00
  - Differential Backup: 09:00 Daily + 21:00 Monday-Saturday
  - Cleanup: Daily 23:00 (removes backups older than 7 days)
  - Recovery Model: SIMPLE (suitable for 12h RPO)

.PARAMETER SqlInstance
  SQL Server instance name (e.g., "localhost" or "SERVER\INSTANCE")

.PARAMETER DatabaseName
  Target database name

.PARAMETER BackupFolder
  Backup destination folder (default: "C:\Daily_backup")

.PARAMETER OwnerAccountSuffix
  Local account suffix for job owner (default: "sqlbackup")

.PARAMETER AgentServerName
  SQL Agent server name (default: "(LOCAL)")

.PARAMETER KeepDays
  Retention period in days (default: 7)

.PARAMETER StartTime
  Backup start time in HH:mm format (default: "21:00"). Secondary slot is calculated as +12 hours.

.PARAMETER DryRun
  Test mode - shows SQL commands without executing

.EXAMPLE
  .\Provision-Backup-12-7-Final.ps1 -SqlInstance "localhost" -DatabaseName "MyDB"

.EXAMPLE
  .\Provision-Backup-12-7-Final.ps1 -SqlInstance "SERVER\INST" -DatabaseName "MyDB" -BackupFolder "D:\Backups" -StartTime "22:30" -DryRun
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)] [string]$SqlInstance,
    [Parameter(Mandatory=$true)] [string]$DatabaseName,
    [string]$BackupFolder       = "C:\Daily_backup",
    [string]$OwnerAccountSuffix = "sqlbackup",
    [string]$AgentServerName    = "(LOCAL)",
    [string]$StartTime          = "21:00",
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
    
    $cmdObj = Get-Command sqlcmd.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmdObj) { 
        throw "sqlcmd.exe not found. Please install SQL Server Command Line Utilities." 
    }

    $tmpFile = [System.IO.Path]::Combine($env:TEMP, "sql_job_$([guid]::NewGuid()).sql")
    
    try {
        # ใช้ UTF8 encoding เพื่อให้ sqlcmd อ่าน Single Quote ได้แม่นยำ
        [System.IO.File]::WriteAllText($tmpFile, $SqlText, [System.Text.Encoding]::UTF8)
        
        $output = & $cmdObj -S "$Server" -d "$Db" -i "$tmpFile" -b 2>&1
        
        if ($LASTEXITCODE -ne 0) { 
            Write-Host "`n[SQLCMD ERROR OUTPUT]" -ForegroundColor Red
            $output | ForEach-Object { Write-Host $_ -ForegroundColor Red }
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
Info "--- Starting Provisioning for Database: $DatabaseName ---"
Info "SQL Instance: $SqlInstance"
Info "Backup Folder: $BackupFolder"
Info "Backup Folder: $BackupFolder"
Info "Start Time: $StartTime"
Info "Retention: $KeepDays days"

# Calculate Schedules
try {
    $tsStart = [TimeSpan]::Parse($StartTime)
    $tsSecondary = $tsStart.Add([TimeSpan]::FromHours(12))
    
    # Normalize to 24h format if > 24h
    if ($tsSecondary.TotalHours -ge 24) {
        $tsSecondary = $tsSecondary.Subtract([TimeSpan]::FromHours(24))
    }

    # Format for SQL Agent (HHmmss)
    $sqlStartTime = "{0:D2}{1:D2}00" -f $tsStart.Hours, $tsStart.Minutes
    $sqlSecondaryTime = "{0:D2}{1:D2}00" -f $tsSecondary.Hours, $tsSecondary.Minutes
    
    Info "Schedule Calculation:"
    Info "  - Primary Slot:   $($tsStart.ToString("hh\:mm")) ($sqlStartTime)"
    Info "  - Secondary Slot: $($tsSecondary.ToString("hh\:mm")) ($sqlSecondaryTime)"
}
catch {
    throw "Invalid StartTime format. Use HH:mm (e.g. 21:00)"
}

# Validate backup folder
if (-not $DryRun) {
    if (-not (Test-Path $BackupFolder)) {
        try {
            New-Item -ItemType Directory -Path $BackupFolder -Force | Out-Null
            Success "Created backup folder: $BackupFolder"
        }
        catch {
            throw "Failed to create backup folder: $_"
        }
    }
    else {
        Info "Backup folder exists: $BackupFolder"
    }
}

$owner = "$env:COMPUTERNAME\$OwnerAccountSuffix"
Info "Job owner: $owner"

# ---- [Step 1] Validate Database & Setup Recovery Model + Roles ----
Info "[Step 1] Configuring database and permissions..."

$setupSql = @"
-- Validate database exists
USE [master];
IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = N'$DatabaseName')
    RAISERROR('Database [$DatabaseName] does not exist', 16, 1);

-- Set Recovery Model to SIMPLE
IF EXISTS (SELECT 1 FROM sys.databases WHERE name = N'$DatabaseName' AND recovery_model_desc <> 'SIMPLE')
BEGIN
    ALTER DATABASE [$DatabaseName] SET RECOVERY SIMPLE;
    PRINT 'Recovery model set to SIMPLE for [$DatabaseName]';
END

-- Setup msdb permissions
USE [msdb];
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$owner')
BEGIN
    CREATE USER [$owner] FOR LOGIN [$owner];
    PRINT 'Created user [$owner] in msdb';
END

IF NOT EXISTS (SELECT 1 FROM sys.database_role_members rm
    JOIN sys.database_principals u ON rm.member_principal_id = u.principal_id
    JOIN sys.database_principals r ON rm.role_principal_id = r.principal_id
    WHERE u.name = N'$owner' AND r.name = N'SQLAgentUserRole')
BEGIN
    EXEC sp_addrolemember N'SQLAgentUserRole', N'$owner';
    PRINT 'Added [$owner] to SQLAgentUserRole';
END

-- Setup database permissions
USE [$DatabaseName];
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$owner')
BEGIN
    CREATE USER [$owner] FOR LOGIN [$owner];
    PRINT 'Created user [$owner] in [$DatabaseName]';
END

IF NOT EXISTS (SELECT 1 FROM sys.database_role_members rm
    JOIN sys.database_principals u ON rm.member_principal_id = u.principal_id
    JOIN sys.database_principals r ON rm.role_principal_id = r.principal_id
    WHERE u.name = N'$owner' AND r.name = N'db_backupoperator')
BEGIN
    EXEC sp_addrolemember N'db_backupoperator', N'$owner';
    PRINT 'Added [$owner] to db_backupoperator role';
END
"@

try {
    Invoke-Tsql -Server $SqlInstance -Db "master" -SqlText $setupSql
    Success "Database configuration completed"
}
catch {
    Error "Failed to configure database: $_"
    throw
}

# ---- [Step 2] Weekly Full Job (Sun 21:00) ----
Info "[Step 2] Creating Weekly Full Backup job..."

$jobF = "Weekly Full Backup (Sun $($tsStart.ToString("hh\:mm"))) - $DatabaseName"
$fullSql = @"
USE [msdb];

-- Create job if not exists
IF NOT EXISTS (SELECT 1 FROM sysjobs WHERE name = N'$jobF')
BEGIN
    EXEC sp_add_job 
        @job_name = N'$jobF', 
        @owner_login_name = N'$owner',
        @description = N'Weekly Full Backup for $DatabaseName (12/7 Strategy)',
        @category_name = N'Database Maintenance';
    PRINT 'Created job: $jobF';
END

-- Create job step
DECLARE @FCmd nvarchar(max) = N'
DECLARE @P nvarchar(400) = N''$BackupFolder\$DatabaseName'' + N''_FULL_'' + 
    REPLACE(REPLACE(REPLACE(CONVERT(nvarchar(19), GETDATE(), 120), N''-'', N''''), N'':'', N''''), N'' '', N''_'') + N''.bak'';
BACKUP DATABASE [$DatabaseName] TO DISK = @P 
WITH COMPRESSION, CHECKSUM, STATS=10, INIT;
PRINT ''Full backup completed: '' + @P;
';

IF NOT EXISTS (SELECT 1 FROM sysjobsteps js JOIN sysjobs j ON j.job_id = js.job_id WHERE j.name = N'$jobF')
BEGIN
    EXEC sp_add_jobstep 
        @job_name = N'$jobF', 
        @step_name = N'Full Backup', 
        @subsystem = N'TSQL', 
        @command = @FCmd,
        @database_name = N'master',
        @on_success_action = 1,
        @on_fail_action = 2,
        @retry_attempts = 2,
        @retry_interval = 5;
    PRINT 'Created job step: Full Backup';
END

-- Schedule: Weekly on Sunday
IF NOT EXISTS (SELECT 1 FROM sysschedules WHERE name = N'WeeklyFullSchedule')
BEGIN
    EXEC sp_add_schedule 
        @schedule_name = N'WeeklyFullSchedule', 
        @freq_type = 8,              -- Weekly
        @freq_interval = 1,          -- Sunday
        @freq_recurrence_factor = 1, -- Every week
        @active_start_time = $sqlStartTime; 
    PRINT 'Created schedule: WeeklyFullSchedule';
END

-- Attach schedule
IF NOT EXISTS (SELECT 1 FROM sysjobschedules js 
    JOIN sysjobs j ON j.job_id = js.job_id 
    JOIN sysschedules s ON s.schedule_id = js.schedule_id
    WHERE j.name = N'$jobF' AND s.name = N'WeeklyFullSchedule')
BEGIN
    EXEC sp_attach_schedule @job_name = N'$jobF', @schedule_name = N'WeeklyFullSchedule';
    PRINT 'Attached WeeklyFullSchedule schedule';
END

-- Add job to server
IF NOT EXISTS (SELECT 1 FROM sysjobservers js JOIN sysjobs j ON j.job_id = js.job_id WHERE j.name = N'$jobF')
BEGIN
    EXEC sp_add_jobserver @job_name = N'$jobF', @server_name = N'$AgentServerName';
    PRINT 'Added job to server';
END
"@

try {
    Invoke-Tsql -Server $SqlInstance -Db "msdb" -SqlText $fullSql
    Success "Weekly Full Backup job created"
}
catch {
    Error "Failed to create Full Backup job: $_"
    throw
}

# ---- [Step 3] 12h Differential Job (09:00 Daily, 21:00 Mon-Sat) ----
Info "[Step 3] Creating 12h Differential Backup job..."

$jobD = "12h Differential Backup ($($tsSecondary.ToString("hh"))/$($tsStart.ToString("hh"))) - $DatabaseName"
$diffSql = @"
USE [msdb];

-- Create job if not exists
IF NOT EXISTS (SELECT 1 FROM sysjobs WHERE name = N'$jobD')
BEGIN
    EXEC sp_add_job 
        @job_name = N'$jobD', 
        @owner_login_name = N'$owner',
        @description = N'Differential backup every 12h for $DatabaseName (12/7 Strategy)',
        @category_name = N'Database Maintenance';
    PRINT 'Created job: $jobD';
END

-- Create job step
DECLARE @DCmd nvarchar(max) = N'
DECLARE @P nvarchar(400) = N''$BackupFolder\$DatabaseName'' + N''_DIFF_'' + 
    REPLACE(REPLACE(REPLACE(CONVERT(nvarchar(19), GETDATE(), 120), N''-'', N''''), N'':'', N''''), N'' '', N''_'') + N''.dif'';
BACKUP DATABASE [$DatabaseName] TO DISK = @P 
WITH DIFFERENTIAL, COMPRESSION, CHECKSUM, STATS=10, INIT;
PRINT ''Differential backup completed: '' + @P;
';

IF NOT EXISTS (SELECT 1 FROM sysjobsteps js JOIN sysjobs j ON j.job_id = js.job_id WHERE j.name = N'$jobD')
BEGIN
    EXEC sp_add_jobstep 
        @job_name = N'$jobD', 
        @step_name = N'Diff Backup', 
        @subsystem = N'TSQL', 
        @command = @DCmd,
        @database_name = N'master',
        @on_success_action = 1,
        @on_fail_action = 2,
        @retry_attempts = 2,
        @retry_interval = 5;
    PRINT 'Created job step: Diff Backup';
END

-- Schedule 1: Daily Secondary Slot (e.g. 09:00)
IF NOT EXISTS (SELECT 1 FROM sysschedules WHERE name = N'DailyDiffSchedule')
BEGIN
    EXEC sp_add_schedule 
        @schedule_name = N'DailyDiffSchedule', 
        @freq_type = 4,              -- Daily
        @freq_interval = 1,          -- Every 1 day
        @active_start_time = $sqlSecondaryTime; 
    PRINT 'Created schedule: DailyDiffSchedule';
END

-- Schedule 2: Monday-Saturday Primary Slot (e.g. 21:00) - exclude Sunday
-- freq_interval bit mask: Mon(2) + Tue(4) + Wed(8) + Thu(16) + Fri(32) + Sat(64) = 126
IF NOT EXISTS (SELECT 1 FROM sysschedules WHERE name = N'MonSatDiffSchedule')
BEGIN
    EXEC sp_add_schedule 
        @schedule_name = N'MonSatDiffSchedule', 
        @freq_type = 8,              -- Weekly
        @freq_interval = 126,        -- Mon-Sat (binary: 1111110)
        @freq_recurrence_factor = 1, -- Every week
        @active_start_time = $sqlStartTime; 
    PRINT 'Created schedule: MonSatDiffSchedule';
END

-- Attach schedules to job
IF NOT EXISTS (SELECT 1 FROM sysjobschedules js 
    JOIN sysjobs j ON j.job_id = js.job_id 
    JOIN sysschedules s ON s.schedule_id = js.schedule_id
    WHERE j.name = N'$jobD' AND s.name = N'DailyDiffSchedule')
BEGIN
    EXEC sp_attach_schedule @job_name = N'$jobD', @schedule_name = N'DailyDiffSchedule';
    PRINT 'Attached DailyDiffSchedule schedule';
END

IF NOT EXISTS (SELECT 1 FROM sysjobschedules js 
    JOIN sysjobs j ON j.job_id = js.job_id 
    JOIN sysschedules s ON s.schedule_id = js.schedule_id
    WHERE j.name = N'$jobD' AND s.name = N'MonSatDiffSchedule')
BEGIN
    EXEC sp_attach_schedule @job_name = N'$jobD', @schedule_name = N'MonSatDiffSchedule';
    PRINT 'Attached MonSatDiffSchedule schedule';
END

-- Add job to server
IF NOT EXISTS (SELECT 1 FROM sysjobservers js JOIN sysjobs j ON j.job_id = js.job_id WHERE j.name = N'$jobD')
BEGIN
    EXEC sp_add_jobserver @job_name = N'$jobD', @server_name = N'$AgentServerName';
    PRINT 'Added job to server';
END
"@

try {
    Invoke-Tsql -Server $SqlInstance -Db "msdb" -SqlText $diffSql
    Success "12h Differential Backup job created"
}
catch {
    Error "Failed to create Differential Backup job: $_"
    throw
}

# ---- [Step 4] Cleanup Job (Daily 23:00) ----


# ---- Summary ----
Write-Host "`n========================================" -ForegroundColor Green
Success "Backup Jobs Provisioned Successfully!"
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Info "Backup Schedule Summary:"
Write-Host "  • Full Backup:        Sunday $($tsStart.ToString("hh\:mm"))" -ForegroundColor White
Write-Host "  • Differential:       Daily $($tsSecondary.ToString("hh\:mm")) + Monday-Saturday $($tsStart.ToString("hh\:mm"))" -ForegroundColor White
Write-Host "  • Cleanup:            (See Provision-Cleanup.ps1)" -ForegroundColor White
Write-Host "  • Recovery Model:     SIMPLE" -ForegroundColor White
Write-Host "  • RPO:                12 hours" -ForegroundColor White
Write-Host "  • Retention:          $KeepDays days" -ForegroundColor White
Write-Host ""
Info "Jobs Created:"
Write-Host "  1. $jobF" -ForegroundColor Cyan
Write-Host "  2. $jobD" -ForegroundColor Cyan

Write-Host ""
Warn "Next Steps:"
Write-Host "  • Verify jobs in SQL Server Agent" -ForegroundColor Yellow
Write-Host "  • Test manual execution: Right-click job > Start Job at Step..." -ForegroundColor Yellow
Write-Host "  • Monitor first automated runs" -ForegroundColor Yellow
Write-Host "  • Verify backup files in: $BackupFolder" -ForegroundColor Yellow
Write-Host ""