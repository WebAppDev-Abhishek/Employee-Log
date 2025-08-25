# 🖥️ Employee Activity Monitor (Tray App)

A lightweight **Windows tray application** built with PowerShell that monitors employee activity, detects idle time, and helps track daily working hours (8/9 hr shifts).  

🚀 Features:
- Runs in the **system tray**
- Detects **idle time** (1 minute inactivity reminder)
- Shows **toast notifications**
- Logs:
  - Start time
  - Idle events
  - Total worked hours
  - "8 hours completed" marker
- **Auto-start at login** (via installer or Task Scheduler)
- Deployable across offices with a single **Setup.exe**

---

## 📦 Installation

### Option 1: Setup.exe Installer (Recommended)
1. Download the latest `EmployeeMonitorSetup.exe` from [Releases](../../releases).
2. Run the installer.
3. The app will be installed to `C:\Program Files\EmployeeMonitor\`.
4. It will auto-start every time the user logs in.

### Option 2: Run directly from PowerShell
```powershell
git clone https://github.com/your-org/EmployeeActivityMonitor.git
cd EmployeeActivityMonitor
powershell.exe -ExecutionPolicy Bypass -STA -File .\EmployeeTrayApp.ps1
