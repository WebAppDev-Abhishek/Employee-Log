<#
.SYNOPSIS
  Employee tray app that monitors activity, logs idle time, 
  shows reminders, and exits after 9 hours.
#>

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

# --- Win32 API to get idle time ---
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

# --- Globals ---
$script:StartTime = Get-Date
$script:IdleLog   = @()
$script:lastIdleOver = $false
$script:EightHourNotified = $false
$script:NineHourNotified  = $false
$LogFile = "$PSScriptRoot\EmployeeLog.txt"

# --- Logging helper ---
function Update-Log($msg) {
    $line = "[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $msg
    Add-Content -Path $LogFile -Value $line
}

Update-Log "Application started at $script:StartTime"

# --- Notification popup ---
function Show-NotificationWindow($Title, $Message) {
    $Width = 360
    $Height = 120
    $wa = [System.Windows.SystemParameters]::WorkArea

    $win = New-Object System.Windows.Window
    $win.Width = $Width
    $win.Height = $Height
    $win.WindowStyle = 'None'
    $win.ResizeMode = 'NoResize'
    $win.AllowsTransparency = $true
    $win.Background = [System.Windows.Media.Brushes]::Transparent
    $win.Topmost = $true
    $win.ShowInTaskbar = $false
    $win.Opacity = 0
    $win.Left = $wa.Right - $Width - 16
    $win.Top  = $wa.Bottom - $Height - 16

    $border = New-Object System.Windows.Controls.Border
    $border.CornerRadius = 14
    $border.Background = [System.Windows.Media.Brushes]::DarkSlateGray
    $border.Padding = 16
    $border.Effect = New-Object System.Windows.Media.Effects.DropShadowEffect -Property @{
        BlurRadius = 18; ShadowDepth = 0; Opacity = 0.35; Color = [System.Windows.Media.Colors]::Black
    }

    $stack = New-Object System.Windows.Controls.StackPanel
    $titleBlock = New-Object System.Windows.Controls.TextBlock
    $titleBlock.Text = $Title
    $titleBlock.Foreground = [System.Windows.Media.Brushes]::White
    $titleBlock.FontSize = 16
    $titleBlock.FontWeight = 'Bold'
    $titleBlock.Margin = '0,0,0,6'

    $msgBlock = New-Object System.Windows.Controls.TextBlock
    $msgBlock.Text = $Message
    $msgBlock.Foreground = [System.Windows.Media.Brushes]::White
    $msgBlock.FontSize = 13
    $msgBlock.TextWrapping = 'Wrap'

    $stack.Children.Add($titleBlock) | Out-Null
    $stack.Children.Add($msgBlock) | Out-Null
    $border.Child = $stack
    $win.Content = $border

    $fadeIn = New-Object System.Windows.Media.Animation.DoubleAnimation 0,1,
        (New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(200)))
    $fadeIn.EasingFunction = New-Object System.Windows.Media.Animation.QuadraticEase -Property @{ EasingMode = 'EaseOut' }

    $win.Add_SourceInitialized({
        $win.BeginAnimation([System.Windows.Window]::OpacityProperty, $fadeIn)
        $timer = New-Object System.Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromSeconds(5)
        $timer.Add_Tick({
            $this.Stop()
            $win.Close()
        })
        $timer.Start()
    })

    $null = $win.Show()
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $win.Add_Closed({ $frame.Continue = $false })
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}

# --- Tray icon ---
$icon = New-Object System.Windows.Forms.NotifyIcon
$icon.Icon = [System.Drawing.SystemIcons]::Information
$icon.Text = "Employee Monitor"
$icon.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip

$showLog = $menu.Items.Add("Show Log")
$showLog.add_Click({ Start-Process notepad.exe $LogFile })

$exitItem = $menu.Items.Add("Exit")
$exitItem.add_Click({
    Update-Log "Application manually exited."
    $icon.Visible = $false
    [System.Windows.Forms.Application]::Exit()
})

$icon.ContextMenuStrip = $menu

# --- Timer loop ---
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 5000   # every 5 seconds
$timer.Add_Tick({
    $idle = [IdleTimeHelper]::GetIdleTime()
    $now = Get-Date
    $uptime = $now - $script:StartTime

    $idleSum = ($script:IdleLog | Measure-Object -Property Duration -Sum).Sum
    if (-not $idleSum) { $idleSum = [TimeSpan]::Zero }
    $worked = ($now - $script:StartTime) - $idleSum

    # --- Idle detection ---
    if ($idle.TotalSeconds -ge 60 -and -not $script:lastIdleOver) {
        Update-Log "User idle for 1+ minute."
        Show-NotificationWindow -Title "Reminder" -Message "You have been inactive for 1 minute."
        $script:IdleLog += [PSCustomObject]@{ Start=$now; Duration=[TimeSpan]::FromMinutes(1) }
        $script:lastIdleOver = $true
    }
    elseif ($idle.TotalSeconds -lt 60 -and $script:lastIdleOver) {
        Update-Log "User resumed activity."
        $script:lastIdleOver = $false
    }

    # --- 8-hour work check ---
    if (-not $script:EightHourNotified -and $worked -ge [TimeSpan]::FromHours(8)) {
        Show-NotificationWindow -Title "Workday Complete" -Message "You have completed 8 hours of work today!"
        Update-Log "8 hours of work completed."
        $script:EightHourNotified = $true
    }

    # --- 9-hour total check ---
    if (-not $script:NineHourNotified -and $uptime -ge [TimeSpan]::FromHours(9)) {
        Show-NotificationWindow -Title "Shift Complete" -Message "9 hours total reached. Exiting."
        Update-Log "Shift complete. 9 hours reached. Application exiting."
        $script:NineHourNotified = $true
        $icon.Visible = $false
        [System.Windows.Forms.Application]::Exit()
    }
})
$timer.Start()

# --- Run tray app ---
[System.Windows.Forms.Application]::Run()
