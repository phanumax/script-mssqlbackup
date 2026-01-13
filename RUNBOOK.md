# SQL Backup & Cleanup Runbook
> **Strategy:** 12/7 Balanced Strategy (RPO 12h, Retention 7 days)
> **Directives:** Aligned with [GEMINI.md](./GEMINI.md) (DevSecOps)

## 1. Overview
This solution provisions a secure, automated backup strategy for SQL Server databases. It is split into two components to enforce **Least Privilege** and **Separation of Concerns**:

| Component | Script | Function | Owner |
| :--- | :--- | :--- | :--- |
| **Backup** | `Provision-Backup-12-7-Final.ps1` | Creates Full (Sun) and Diff (Daily/12h) jobs. | Standard User (e.g., `sqlbackup`) |
| **Cleanup** | `Provision-Cleanup.ps1` | Creates Cleanup job (Daily) to purge old files. | `sa` (System Admin) |

---

## 2. Prerequisites
-   **PowerShell** (v5.1 or Core)
-   **SQL Server Command Line Utilities** (`sqlcmd`)
-   Access to the target SQL Instance.
-   **Permissions**:
    -   To run *Backup Script*: User needs `db_owner` or `db_backupoperator` rights.
    -   To run *Cleanup Script*: User needs `sysadmin` rights (to assign `sa` ownership).

---

## 3. Provisioning Steps (Deployment)

### Step 1: Provision Backup Jobs
Run this as a standard user or admin. This sets up the core data protection.

```powershell
.\Provision-Backup-12-7-Final.ps1 -SqlInstance "LOCALHOST" -DatabaseName "TargetDB" -BackupFolder "C:\Backups" -StartTime "21:00"
```

**Parameters:**
- `StartTime`: (Optional) The time for the primary backup slot (e.g., "22:30"). The secondary slot is automatically calculated +12h later. Default is "21:00".

**Outcome:**
-   Job: `Weekly Full Backup (Sun [StartTime]) - TargetDB` created.
-   Job: `12h Differential Backup (Daily) - TargetDB` created.
-   **Note:** These jobs run as the specified owner (default `sqlbackup`).

### Step 2: Provision Cleanup Job
Run this as an Administrator (`sysadmin`). This sets up the maintenance task.

```powershell
.\Provision-Cleanup.ps1 -SqlInstance "LOCALHOST" -DatabaseName "TargetDB" -BackupFolder "C:\Backups" -KeepDays 7
```

**Outcome:**
-   Job: `Backup Cleanup (23:00) - TargetDB` created.
-   **Note:** This job is owned by `sa` to authorize `xp_delete_file` execution.

---

## 4. Verification
1.  Open **SQL Server Management Studio (SSMS)**.
2.  Expand **SQL Server Agent** > **Jobs**.
3.  Verify the following 3 jobs exist for your database:
    -   `Weekly Full Backup...`
    -   `12h Differential Backup...`
    -   `Backup Cleanup...`
4.  **Verify Schedules:** 
    -   Check that the Full Backup runs at the specified `-StartTime`.
    -   Check that the Differential Backup has two schedules: one at `-StartTime` (Mon-Sat) and one at `StartTime + 12h` (Daily).
5.  **Right-click** the Cleanup job > **Properties**. Ensure **Owner** is `sa`.

---

## 5. Troubleshooting

### Permission Denied on Cleanup
**Symptom:** `Executed as user: ... The EXECUTE permission was denied on the object 'xp_delete_file' ...`
**Cause:** The Cleanup Job is owned by a non-sysadmin user.
**Fix:**
Re-run `Provision-Cleanup.ps1`. It enforces `sa` ownership.

### Job Fails or Files Not Deleted
-   Check the **Job History** in SSMS.
-   Ensure the `BackupFolder` path exists and the SQL Agent Service Account has **Write/Modify** permissions on that folder.

### Script Not Digitally Signed / UnauthorizedAccess
**Symptom:** `File ... cannot be loaded. The file ... is not digitally signed.`
**Cause:** PowerShell Execution Policy blocks running unsigned scripts downloaded from the internet.
**Fix:**
Run the script with the Bypass flag:
```powershell
PowerShell.exe -ExecutionPolicy Bypass -File .\Provision-Backup-12-7-Final.ps1 ...
```
Or unblock the file permanently:
```powershell
Unblock-File -Path .\Provision-Backup-12-7-Final.ps1
```

---

## 6. Rollback / Uninstall
To remove the provisioning:
1.  Open SSMS > SQL Server Agent > Jobs.
2.  Delete the 3 jobs associated with the database.
3.  (Optional) Remove `sqlbackup` user from the database if no longer needed.

---

## 7. Disaster Recovery (Restore Procedure)

> **CRITICAL:** Before restoring, ensure you have identified the correct point-in-time you wish to return to. The 12/7 strategy creates a dependency chain: **Last Full Backup** -> **Latest Differential Backup**.

### Scenario: Restore to the latest available point
Suppose you need to restore `TargetDB` after a crash on **Wednesday morning (10:00)**.
Required Files:
1.  **Weekly Full Backup:** From Sunday night.
2.  **Latest Differential Backup:** From Wednesday morning (09:00, if it ran) or Tuesday night (21:00).

### Step 1: Restore Weekly Full Backup (NORECOVERY)
The database must remain in a `RESTORING` state to accept subsequent differential backups. **DO NOT** bring the database online yet.

```sql
USE [master];
-- Close active connections (Optional but recommended)
ALTER DATABASE [TargetDB] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;

RESTORE DATABASE [TargetDB] 
FROM DISK = N'C:\Backups\TargetDB_FULL_YYYYMMDD_HHMMSS.bak'
WITH 
    NORECOVERY, -- Keep database in 'Restoring' state
    REPLACE,    -- Overwrite existing database if necessary
    STATS = 10;
```

### Step 2: Restore Latest Differential Backup (RECOVERY)
This applies all changes since the full backup and brings the database online.

```sql
RESTORE DATABASE [TargetDB] 
FROM DISK = N'C:\Backups\TargetDB_DIFF_YYYYMMDD_HHMMSS.dif'
WITH 
    RECOVERY,   -- Bring database ONLINE
    STATS = 10;
```

### Step 3: Verify and Reset Access
```sql
USE [master];
-- Set multi-user mode back
ALTER DATABASE [TargetDB] SET MULTI_USER;

-- Verify
USE [TargetDB];
SELECT count(*) FROM [SomeCriticalTable];
```

### FAQ: What if I only have a Full Backup?
If you just want to restore the Full Backup (e.g., from Sunday) and ignore the differentials:
-   Change Step 1 to use `WITH RECOVERY` directly.
-   Skip Step 2.
