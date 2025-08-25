<#
.SYNOPSIS
  Employee Activity Tray App with WPF Log Viewer
  - Runs in system tray
  - Detects 1 min inactivity and shows toast
  - Tracks total idle and worked time
  - Notifies at 8 hours worked
  - Exits at 9 hours total
  - WPF Log Window (double-click tray or menu)
  - Daily log file in C:\ProgramData\EmployeeMonitor\
#>

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

# ---------- Win32 Idle API ----------
Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class IdleTimeHelper {
    [StructLayout(LayoutKind.Sequential)]
    struct LASTINPUTINFO {
        public uint cbSize;
        public uint dwTime;
    }
    [DllImport("user32.dll")]
    static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

    public static TimeSpan GetIdleTime() {
        LASTINPUTINFO info = new LASTINPUTINFO();
        info.cbSize = (uint)System.Runtime.InteropServices.Marshal.SizeOf(info);
        GetLastInputInfo(ref info);
        return TimeSpan.FromMilliseconds(Environment.TickCount - info.dwTime);
    }
}
"@

# ---------- Globals ----------
$script:StartTime          = Get-Date
$script:IsIdle             = $false
$script:IdleStart          = $null
$script:TotalIdle          = [TimeSpan]::Zero
$script:IdleEvents         = New-Object System.Collections.ArrayList
$script:Notified8h         = $false
$script:Notified9h         = $false

# Daily log file (per system date)
$LogDir  = "C:\ProgramData\EmployeeMonitor"
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }
$LogFile = Join-Path $LogDir ("Log-{0:yyyy-MM-dd}.txt" -f (Get-Date))

function Update-Log([string]$Message) {
    $line = "[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $Message
    Add-Content -Path $LogFile -Value $line
}

Update-Log "Session started."

# ---------- Toast notification ----------
function Show-NotificationWindow($Title, $Message) {
    $Width = 340; $Height = 110
    $wa = [System.Windows.SystemParameters]::WorkArea

    $win = New-Object System.Windows.Window -Property @{
        Width=$Width; Height=$Height; WindowStyle='None'; ResizeMode='NoResize'
        AllowsTransparency=$true; Background=[System.Windows.Media.Brushes]::Transparent
        Topmost=$true; ShowInTaskbar=$false; Opacity=0
        Left=($wa.Right - $Width - 16); Top=($wa.Bottom - $Height - 16)
    }

    $border = New-Object System.Windows.Controls.Border
    $border.CornerRadius = 12
    $border.Background   = [System.Windows.Media.Brushes]::DarkSlateGray
    $border.Padding      = 14
    $border.Effect       = New-Object System.Windows.Media.Effects.DropShadowEffect -Property @{ BlurRadius=14; ShadowDepth=0; Opacity=0.4 }

    $stack = New-Object System.Windows.Controls.StackPanel
    $titleBlock = New-Object System.Windows.Controls.TextBlock -Property @{
        Text=$Title; FontSize=15; FontWeight='Bold'; Foreground=[System.Windows.Media.Brushes]::White; Margin='0,0,0,6'
    }
    $msgBlock = New-Object System.Windows.Controls.TextBlock -Property @{
        Text=$Message; FontSize=13; Foreground=[System.Windows.Media.Brushes]::White; TextWrapping='Wrap'
    }
    $stack.Children.Add($titleBlock) | Out-Null
    $stack.Children.Add($msgBlock)  | Out-Null
    $border.Child = $stack
    $win.Content = $border

    $fadeIn = New-Object System.Windows.Media.Animation.DoubleAnimation(0,1,[System.Windows.Duration]::FromMilliseconds(180))
    $win.Add_SourceInitialized({
        $win.BeginAnimation([System.Windows.Window]::OpacityProperty,$fadeIn)
        $timer = New-Object System.Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromSeconds(5)
        $timer.Add_Tick({ $this.Stop(); $win.Close() })
        $timer.Start()
    })

    $null  = $win.Show()
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $win.Add_Closed({ $frame.Continue = $false })
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}

# ---------- Helper: current worked and uptime ----------
function Get-SessionTimes {
    $now    = Get-Date
    $uptime = $now - $script:StartTime
    $effectiveIdle = $script:TotalIdle
    if ($script:IsIdle -and $script:IdleStart) {
        # Count ongoing idle into total for display
        $effectiveIdle += ($now - $script:IdleStart)
    }
    $worked = $uptime - $effectiveIdle
    [pscustomobject]@{ Now=$now; Uptime=$uptime; TotalIdle=$effectiveIdle; Worked=$worked }
}

# ---------- WPF Log Viewer ----------
function Show-LogWindow {
    # Window
    $win = New-Object System.Windows.Window -Property @{
        Title="Employee Work Log"; Width=700; Height=520; WindowStartupLocation='CenterScreen'
    }

    # Layout grid (2 rows)
    $grid = New-Object System.Windows.Controls.Grid
    $grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{Height='Auto'}))
    $grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{Height='*'}))

    # Stats panel
    $stats = New-Object System.Windows.Controls.TextBlock -Property @{
        Margin= '12'; FontFamily='Consolas'; FontSize=13
    }
    [System.Windows.Controls.Grid]::SetRow($stats,0)

    # Log content box
    $tb = New-Object System.Windows.Controls.TextBox -Property @{
        Margin='12'; FontFamily='Consolas'; FontSize=12
        IsReadOnly=$true; AcceptsReturn=$true; VerticalScrollBarVisibility='Auto'; HorizontalScrollBarVisibility='Auto'
    }
    [System.Windows.Controls.Grid]::SetRow($tb,1)

    $grid.Children.Add($stats) | Out-Null
    $grid.Children.Add($tb)    | Out-Null
    $win.Content = $grid

    # Refresh function
    $refresh = {
        $t = Get-SessionTimes
        $remaining = [TimeSpan]::FromHours(8) - $t.Worked
        if ($remaining -lt [TimeSpan]::Zero) { $remaining = [TimeSpan]::Zero }
        $stats.Text =
@"
Start    : $($script:StartTime)
Now      : $($t.Now)
Uptime   : $("{0:hh\:mm\:ss}" -f $t.Uptime)
Idle     : $("{0:hh\:mm\:ss}" -f $t.TotalIdle)
Worked   : $("{0:hh\:mm\:ss}" -f $t.Worked)
To 8 hrs : $("{0:hh\:mm\:ss}" -f $remaining)
Status   : $(if($t.Worked.TotalHours -ge 8){"✅ 8 hours completed"}else{"Working"})
"@

        if (Test-Path $LogFile) {
            $tb.Text = (Get-Content -Path $LogFile -ErrorAction SilentlyContinue) -join "`r`n"
            $tb.CaretIndex = $tb.Text.Length
            $tb.ScrollToEnd()
        } else {
            $tb.Text = "No log file yet: $LogFile"
        }
    }

    # Auto-refresh inside the window
    $dt = New-Object System.Windows.Threading.DispatcherTimer
    $dt.Interval = [TimeSpan]::FromSeconds(3)
    $dt.Add_Tick($refresh)
    $dt.Start()

    $refresh.Invoke()
    $win.ShowDialog() | Out-Null
}

# ---------- Tray icon ----------
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon  = [System.Drawing.SystemIcons]::Information
$tray.Text  = "Employee Monitor"
$tray.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip

$openViewer = $menu.Items.Add("Open Log Window")
$openViewer.add_Click({ Show-LogWindow })

$openNotepad = $menu.Items.Add("Open Log in Notepad")
$openNotepad.add_Click({ Start-Process notepad.exe $LogFile })

$exitItem = $menu.Items.Add("Exit")
$exitItem.add_Click({
    Update-Log "Application manually exited."
    $tray.Visible = $false
    [System.Windows.Forms.Application]::Exit()
})

# Double-click tray to open viewer
$tray.add_DoubleClick({ Show-LogWindow })
$tray.ContextMenuStrip = $menu

# ---------- Timer loop (every 5s) ----------
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 5000
$timer.Add_Tick({
    $idle = [IdleTimeHelper]::GetIdleTime()
    $now  = Get-Date

    # Enter idle state if first time crossing 60s
    if (-not $script:IsIdle -and $idle.TotalSeconds -ge 60) {
        # Estimate idle start = now - idle duration
        $script:IsIdle = $true
        $script:IdleStart = $now.AddSeconds(-[int]$idle.TotalSeconds)
        [void]$script:IdleEvents.Add([pscustomobject]@{Start=$script:IdleStart; End=$null; Duration=$null})
        Update-Log ("Idle started (≥1 min). Since: {0:HH:mm:ss}" -f $script:IdleStart)
        Show-NotificationWindow -Title "Reminder" -Message "You have been inactive for 1 minute."
    }

    # Exit idle state when user active again
    if ($script:IsIdle -and $idle.TotalSeconds -lt 60) {
        $script:IsIdle = $false
        $idleEnd = $now
        if ($script:IdleStart) {
            $dur = $idleEnd - $script:IdleStart
            $script:TotalIdle += $dur
            # Update last event with end/duration
            $last = $script:IdleEvents[$script:IdleEvents.Count-1]
            $last.End = $idleEnd
            $last.Duration = $dur
            Update-Log ("User resumed. Idle duration: {0:hh\:mm\:ss}" -f $dur)
            $script:IdleStart = $null
        } else {
            Update-Log "User resumed."
        }
    }

    # Work/uptime checks
    $t = Get-SessionTimes
    if (-not $script:Notified8h -and $t.Worked.TotalHours -ge 8) {
        Show-NotificationWindow -Title "Workday Complete" -Message "You have completed 8 hours of work today!"
        Update-Log "8 hours of effective work completed."
        $script:Notified8h = $true
    }

    if (-not $script:Notified9h -and $t.Uptime.TotalHours -ge 9) {
        Show-NotificationWindow -Title "Shift Complete" -Message "9 hours total reached. Exiting."
        Update-Log "9 hours total reached. Application exiting."
        $script:Notified9h = $true
        $tray.Visible = $false
        [System.Windows.Forms.Application]::Exit()
    }
})
$timer.Start()

# ---------- Run tray app ----------
[System.Windows.Forms.Application]::Run()
