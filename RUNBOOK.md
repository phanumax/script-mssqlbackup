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
.\Provision-Backup-12-7-Final.ps1 -SqlInstance "LOCALHOST" -DatabaseName "TargetDB" -BackupFolder "C:\Backups"
```

**Outcome:**
-   Job: `Weekly Full Backup (Sun 21:00) - TargetDB` created.
-   Job: `12h Differential Backup (09/21) - TargetDB` created.
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
4.  **Right-click** the Cleanup job > **Properties**. Ensure **Owner** is `sa`.

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

---

## 6. Rollback / Uninstall
To remove the provisioning:
1.  Open SSMS > SQL Server Agent > Jobs.
2.  Delete the 3 jobs associated with the database.
3.  (Optional) Remove `sqlbackup` user from the database if no longer needed.
