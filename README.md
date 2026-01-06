# SQL Backup Strategy (12/7)

A robust, automated SQL Server backup solution designed with **DevSecOps** principles.

## Strategy Overview
- **RPO:** 12 Hours
- **Retention:** 7 Days
- **Model:** SIMPLE Recovery Model

## Components
1.  **Backup Provisioning** (`Provision-Backup-12-7-Final.ps1`):
    -   Sets up **Weekly Full** (Sun 21:00) and **Daily Differential** (09:00, 21:00) backups.
    -   Runs with standard privileges.
2.  **Cleanup Provisioning** (`Provision-Cleanup.ps1`):
    -   Sets up the **Daily Cleanup** job (23:00).
    -   Owned by `sa` to safely execute `xp_delete_file` for file maintenance.

## Documentation
Please refer to the [RUNBOOK.md](./RUNBOOK.md) for detailed deployment, verification, and troubleshooting instructions.
