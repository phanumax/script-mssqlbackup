# CAB Presentation: SQL Backup Strategy Enhancement (12/7)

**Date:** 2026-01-06
**Project:** SQL Server 12/7 Backup Strategy
**Presenter:** [Name]

---

## 1. Executive Summary
We are implementing a standardized **12/7 Backup Strategy** (12-hour RPO, 7-day Retention) for critical SQL Server databases. This change introduces automated, secure provisioning scripts that separate operational backup tasks from administrative maintenance, enforcing **Least Privilege**.

## 2. Business Goal & Value
*   **Reliability:** Guarantees uniform 12-hour Recovery Point Objective (RPO).
*   **Compliance:** Enforces 7-day retention policy automatically.
*   **Security:** Fixes permission issues by isolating high-privilege cleanup tasks from standard backup operations.

## 3. The 12/7 Strategy
| Component | Detail | Schedule |
| :--- | :--- | :--- |
| **Full Backup** | Complete database copy | **Sundays 21:00** |
| **Diff Backup** | Changes since last Full | **Daily 09:00 + Mon-Sat 21:00** |
| **Cleanup** | Auto-remove files > 7 days | **Daily 23:00** |

## 4. Implementation Details (Technical)
We have refactored the provisioning process into two distinct components to satisfy **DevSecOps** principles:

### A. Operational Backups (Standard User)
*   **Script:** `Provision-Backup-12-7-Final.ps1`
*   **Owner:** Standard Service Account (`sqlbackup`)
*   **Scope:** Creates Full and Differential jobs only.
*   **Risk:** Low (Standard SQL permissions).

### B. Maintenance/Cleanup (Admin)
*   **Script:** `Provision-Cleanup.ps1`
*   **Owner:** System Administrator (`sa`)
*   **Rationale:** The cleanup command (`xp_delete_file`) dictates `sysadmin` privileges. By isolating this into a separate job owned by `sa`, we avoid granting elevated rights to the standard backup user.

## 5. Risk Assessment & Mitigation
| Risk | Probability | Impact | Mitigation |
| :--- | :--- | :--- | :--- |
| **Job Failure** | Low | Medium | SQL Agent Alerts + Daily Monitoring. |
| **Privilege Escalation** | Low | High | Separation of Duties (Cleanup uses specific script). |
| **Data Loss** | Very Low | Critical | DRY RUN verification before deployment; Standard Recovery Model (SIMPLE). |

## 6. Rollback Plan
1.  **Stop Jobs:** Disable the created SQL Agent jobs.
2.  **Delete Jobs:** Remove `Weekly Full...`, `12h Differential...`, and `Backup Cleanup...` from SQL Agent.
3.  **Restore:** (If needed) Re-enable previous maintenance plans.

## 7. Request for Approval
Requesting approval to deploy the **Separated Provisioning Scripts** to [Target Enironment/Production].
