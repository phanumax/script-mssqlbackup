# 📘 Runbook: SQL Server Transaction Log Management

เอกสารฉบับนี้ใช้สำหรับแนวทางปฏิบัติในการตรวจสอบ จัดการ และแก้ไขปัญหาไฟล์ Transaction Log (.ldf) บวม เพื่อป้องกันปัญหา Disk เต็มและรักษาความเสถียรของระบบฐานข้อมูล

## 🔍 1. การตรวจสอบสถานะ (Health Check)

ก่อนดำเนินการใดๆ ให้ตรวจสอบสัดส่วนการใช้งานพื้นที่ Log จริงเทียบกับขนาดไฟล์ที่จองไว้บน Disk

```sql
-- คำสั่งตรวจสอบพื้นที่ใช้งานของ Log ในทุก Database
DBCC SQLPERF(logspace);

```

### การวิเคราะห์ผลลัพธ์ (Analysis)

| สถานะ | ความหมาย | แนวทางปฏิบัติ |
| --- | --- | --- |
| **Log Space Used (%) ต่ำ** | มีพื้นที่ว่างในไฟล์เยอะ (เช่น PRSystem ในเคสล่าสุด) | สามารถสั่ง `SHRINKFILE` คืนพื้นที่ให้ Windows ได้ทันที |
| **Log Space Used (%) สูง** | Transaction เต็มไฟล์ (เช่น PRSystem_DEV 99%) | **ห้าม** Shrink ทันที ต้องทำ Log Backup หรือเปลี่ยน Recovery Model ก่อน |

---

## 🛠 2. ขั้นตอนการลดขนาดไฟล์ฉุกเฉิน (Emergency Shrink)

ใช้ในกรณีที่ Disk ใกล้เต็มและต้องการพื้นที่คืนทันที โดยใช้วิธีเปลี่ยน Recovery Model ชั่วคราว (ไม่ต้องใช้พื้นที่ Disk เพิ่มในการ Backup)

### Step 1: ตรวจสอบ Logical Name

```sql
USE [YourDatabaseName];
SELECT name AS LogicalName FROM sys.database_files WHERE type_desc = 'LOG';

```

### Step 2: ดำเนินการ T-SQL

```sql
-- 1. เปลี่ยนเป็น SIMPLE เพื่อตัด Chain ของ Log ที่ค้างอยู่
ALTER DATABASE [YourDatabaseName] SET RECOVERY SIMPLE;
GO

-- 2. สั่งหดไฟล์ (ระบุ Logical Name จาก Step 1)
-- กำหนดเป้าหมายที่ 1024MB (1GB)
DBCC SHRINKFILE (N'YourLogicalLogName', 1024);
GO

-- 3. เปลี่ยนกลับเป็น FULL
ALTER DATABASE [YourDatabaseName] SET RECOVERY FULL;
GO

```

> [!CAUTION]
> **Important:** หลังจากเปลี่ยนกลับเป็น `FULL` แล้ว ต้องรัน **Full Backup** ฐานข้อมูลทันที 1 ครั้ง เพื่อเริ่มเก็บประวัติสำรองข้อมูลใหม่ (Restart Backup Chain)

---

## 🚀 3. แนวทางปฏิบัติระยะยาว (Best Practices)

### 3.1 การตั้งค่า Autogrowth (File Growth)

เพื่อประสิทธิภาพสูงสุดและลด Disk Fragmentation ควรตั้งค่าเป็นค่าคงที่ (Fixed Amount) ไม่ควรตั้งเป็นเปอร์เซ็นต์

```sql
-- แนะนำให้ตั้งเป็น 256MB หรือ 512MB ตามขนาดฐานข้อมูล
ALTER DATABASE [YourDatabaseName] 
MODIFY FILE ( NAME = N'YourLogicalLogName', FILEGROWTH = 256MB );

```

### 3.2 Recovery Model & Backup Strategy

* **Simple Model:** เหมาะสำหรับฐานข้อมูล Dev/UAT หรือระบบที่ไม่ต้องการ Point-in-time Recovery
* **Full Model:** ต้องมีการทำ **Transaction Log Backup Job** (เช่น ทุก 15-30 นาที) เพื่อระบายพื้นที่ Log เสมอ มิฉะนั้นไฟล์จะบวมจน Disk เต็ม

---

## ⚠️ 4. การแก้ไขปัญหาเพิ่มเติม (Troubleshooting)

| อาการ | สาเหตุที่พบบ่อย | วิธีแก้ไข |
| --- | --- | --- |
| Shrink แล้วขนาดไฟล์ไม่ลด | มี Transaction ขนาดใหญ่ค้างอยู่ | ใช้ `DBCC OPENTRAN` ตรวจสอบและ Kill session ที่ค้าง |
| Log บวมเร็วผิดปกติ | มีการทำ Index Rebuild หรือ Bulk Insert | พิจารณาทำช่วง Off-peak หรือเปลี่ยนเป็น Simple ชั่วคราว |
| Status ใน SQLPERF ไม่เป็น 0 | ฐานข้อมูลมีปัญหาเรื่องความคงสภาพ | ตรวจสอบ Error Log ใน SQL Server Management Studio (SSMS) |

---

**Last Updated:** 2026-01-13
**Created by:** IT Admin Team

