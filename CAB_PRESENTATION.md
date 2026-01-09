# Change Advisory Board (CAB) Presentation
## Title: Implementation of 12/7 SQL Backup Strategy

> **Date:** 2026-01-07
> **Presenter:** DevOps Team
> **Risk Level:** Medium (Service Impact during execution)

---

### 1. Executive Summary
ขออนุมัติ Deploy ระบบ **Automated SQL Backup** และทำ **Storage Optimization** เนื่องจากการตรวจสอบพบว่า Transaction Log มีขนาดใหญ่ผิดปกติ (Bloated Log)

**Objective:**
- ปรับใช้ Strategy แบบ **12/7** (Weekly Full + Daily/12h Differential)
- แก้ปัญหา **Transaction Log บวม (56GB)** โดยการ Resize กลับสู่ขนาดปกติ (Reclaim Space)
- ลดความเสี่ยง Data Loss และลด **RPO** เหลือ 12 ชั่วโมง

---

### 2. Change Scope
- **Deploy Scripts:**
    - `Provision-Backup-12-7-Final.ps1`: สร้าง Backup Job และ Force Set Recovery Model เป็น **SIMPLE**
    - `Provision-BackupUser.ps1`: สำหรับสร้าง Service Account และกำหนดสิทธิ์
- **Target System:** Database `PRSystem`
- **Cleanup Process:** SysAdmin จะดูแลการลบไฟล์เก่า (Manual Process)

---

### 3. Impact Analysis & Optimization Plan
**⚠️ Current State Analysis:**
จากภาพ Log File Usage พบความผิดปกติ:
- **Data File (.mdf):** ~10 GB (Normal Size)
- **Log File (.ldf):** **~56 GB** (Critical - ใหญ่กว่าข้อมูลจริง 5 เท่า)

**Optimization Benefit:**
หลังการเปลี่ยน Recovery Model เป็น SIMPLE จะสามารถทำ **Log Shrink** เพื่อขอคืนพื้นที่ Storage ได้ประมาณ **50 GB**

**Downtime Requirement:**
ขอเสนอ **Maintenance Window 1 ชั่วโมง** (Sunday 21:00) เพื่อดำเนินการ:
1.  Full Backup ข้อมูลปัจจุบัน (10GB)
2.  Switch Recovery Model -> SIMPLE
3.  **Halt Operations & Shrink Log File** (ลดขนาดจาก 56GB -> <1GB)

---

### 4. Implementation Steps
1.  **Prep:** เช็ค Disk Space (ต้องว่าง > 30GB สำหรับ Backup ก่อน Shrink)
2.  **Create User:** รัน `Provision-BackupUser.ps1`
3.  **Execute Provisioning:** รัน PowerShell Script เพื่อสร้าง Job บน SQL Agent
4.  **Full Backup:** สั่ง Start Job "Weekly Full Backup" ทันที
5.  **Optimization:** รัน `DBCC SHRINKFILE` เพื่อคืนพื้นที่ 50GB

---

### 5. Risk & Mitigation
| Risk | Probability | Mitigation |
| :--- | :--- | :--- |
| **Log Shrink Fail** | Low | ทำ Full Backup ไว้ก่อนดำเนินการเสมอ |
| **I/O Overhead** | High | ทำงานในช่วง Maintenance Window เท่านั้น |

---

### 6. Rollback Plan
1.  **Restore:** หากข้อมูลเสียหาย ให้ Restore จากไฟล์ Full Backup ที่ทำไว้ในขั้นตอนที่ 4
2.  **Revert Job:** Disable SQL Agent Job ที่สร้างใหม่

---

### 7. Approval Request
ขออนุมัติ Deploy และทำ Storage Optimization เพื่อเรียกคืนพื้นที่ 50GB ใน Maintenance Window รอบถัดไป
