# Maintenance Procedure: Initial Deployment & Log Optimization
> **เอกสารคู่มือการปฏิบัติงาน (Work Instruction)**
> **เป้าหมาย:** ติดตั้งระบบ Backup ใหม่ และลดขนาด Transaction Log (56GB -> 1GB)
> **ระยะเวลา:** 1 ชั่วโมง (Maintenance Window)

---

## 1. Preparation (ก่อนเริ่ม)
*   [ ] **Notify Users:** แจ้งผู้ใช้งานว่าจะมีการปิดระบบชั่วคราว (21:00 - 22:00)
*   [ ] **Check Disk Space:** Drive C: แะล Drive D: (ที่เก็บ Backup) ต้องมีพื้นที่ว่าง **> 30 GB**
    *   *เหตุผล:* ต้องใช้พื้นที่สำหรับ Full Backup ครั้งแรก (10GB) และเผื่อไว้กันพลาด

## 2. Execution Steps (ขั้นตอนปฏิบัติ)

### Step 1: Stop Applications (21:00)
เพื่อให้ Database ตัด Transaction และป้องกันข้อมูลไหลเข้าระหว่างทำ
*   [ ] Stop Web Server / Application Service ที่เชื่อมต่อ Database `PRSystem`

### Step 2: Create User & Assign Roles
ต้องสร้าง User ให้เรียบร้อยก่อน ถึงจะรัน Script สร้าง Backup Job ได้
```powershell
# รันด้วยสิทธิ์ Administrator
.\Provision-BackupUser.ps1 -SqlInstance "LOCALHOST" -DatabaseName "PRSystem"
```
*   *Action:* สร้าง Login `[MachineName]\sqlbackup`
*   *Action:* ให้สิทธิ์ `SQLAgentUserRole` (ใน msdb)
*   *Action:* ให้สิทธิ์ `db_backupoperator` (ใน Target DB)

### Step 3: Provision Scripts & Set SIMPLE Recovery
รัน PowerShell เพื่อสร้าง Job และเปลี่ยน Recovery Model เป็น SIMPLE
```powershell
# รันด้วยสิทธิ์ Administrator
.\Provision-Backup-12-7-Final.ps1 -SqlInstance "LOCALHOST" -DatabaseName "PRSystem" -BackupFolder "D:\Backups" -StartTime "21:00"
.\Provision-Cleanup.ps1 -SqlInstance "LOCALHOST" -DatabaseName "PRSystem" -BackupFolder "D:\Backups" -KeepDays 7
```
*   *Note:* `-StartTime` กำหนดเวลา Full Backup (Default 21:00) และระบบจะคำนวณรอบถัดไป +12 ชม. ให้เอง
*   **Check:** หน้าจอต้องขึ้น `[SUCCESS]` และไม่มี Error สีแดง

### Step 4: Force Full Backup (Critical)
เราต้องทำ Full Backup หนึ่งครั้งก่อนที่จะแตะต้อง Log File
1.  เปิด **SSMS** > Connect Database
2.  ไปที่ **SQL Server Agent** > **Jobs**
3.  คลิกขวาที่ Job: `Weekly Full Backup (Sun 21:00) - PRSystem`
4.  เลือก **Start Job at Step...**
5.  **Wait:** รอจนกว่า Job จะขึ้น Status **Succeeded** (ใช้เวลาประมาณ 10-20 นาที)
6.  **Verify File:** ไปดูที่ Folder `D:\Backups` ต้องมีไฟล์ `.bak` ขนาด ~10GB

### Step 5: Shrink Log File (The Optimization)
เมื่อ Backup เสร็จแล้ว และ Recovery Model เป็น SIMPLE (จาก Step 3) เราจะคืนพื้นที่ Log
1.  ใน SSMS > **New Query**
2.  รันคำสั่ง T-SQL ด้านล่าง:
    ```sql
    USE [PRSystem];
    GO
    -- ตรวจสอบชื่อ Log File (ปกติคือ PRSystem_Log)
    -- สั่ง Shrink ให้เหลือ 1GB (1024MB)
    DBCC SHRINKFILE (N'PRSystem_Log' , 1024);
    GO
    ```
3.  **Verify:**
    *   Message ต้องขึ้นว่า `Log file ... shrunk.`
    *   เข้าไปดู Database Properties > Files
    *   ไฟล์ Log (.ldf) ต้องมีขนาดลดลงเหลือประมาณ **1 GB** (จากเดิม 56GB)

## 3. Post-Action (หลังจบงาน)

### Step 6: Start Applications (22:00)
*   [ ] Start Web Server / Application Service
*   [ ] Test Login และใช้งานระบบ

### Step 7: Final Check Script
*   [ ] รัน `Verify-BackupSetup.ps1` เพื่อยืนยันความถูกต้องของระบบทั้งหมด
    ```powershell
    .\Verify-BackupSetup.ps1 -SqlInstance "LOCALHOST" -DatabaseName "PRSystem"
    ```

---

## Emergency Rollback
หากเกิดปัญหาร้ายแรง:
1.  **Restrict Access:** ห้ามเปิด App
2.  **Restore:** ใช้ไฟล์ Full Backup ล่าสุด Restore ทับ
    ```sql
    RESTORE DATABASE [PRSystem] FROM DISK = 'D:\Backups\PRSystem_FULL_xxxx.bak' WITH REPLACE;
    ```
