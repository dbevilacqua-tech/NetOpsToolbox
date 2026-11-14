[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Scope = 'Function', Target = '*-NetOps*', Justification = 'Controls in-memory WPF state and the window-owned diagnostic worker.')]
param()

Set-StrictMode -Version 3.0
Import-Module (Join-Path $PSScriptRoot 'NetOps.Common.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'NetOps.Runner.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'NetOps.Reports.psm1') -ErrorAction Stop

$script:Ui = $null

function Set-NetOpsStatus {
    param([string]$Text, [string]$Brush = 'MutedBrush')

    $status = $script:Ui.Controls.StatusText
    if ($status.Text -ne $Text) {
        $status.Text = $Text
        $status.ToolTip = $Text
    }
    $status.Foreground = $script:Ui.Window.FindResource($Brush)
}

function Get-NetOpsLuminance {
    param([Windows.Media.Color]$Color)

    $linear = foreach ($value in $Color.R, $Color.G, $Color.B) {
        $channel = $value / 255.0
        if ($channel -le 0.04045) { $channel / 12.92 }
        else { [Math]::Pow(($channel + 0.055) / 1.055, 2.4) }
    }
    return (0.2126 * $linear[0] + 0.7152 * $linear[1] + 0.0722 * $linear[2])
}

function New-NetOpsReadableBrush {
    param([Windows.Media.Color]$Background, [Windows.Media.Color]$Preferred)

    $surface = Get-NetOpsLuminance $Background
    $text = Get-NetOpsLuminance $Preferred
    $contrast = ([Math]::Max($surface, $text) + 0.05) / ([Math]::Min($surface, $text) + 0.05)
    if ($contrast -lt 4.5) {
        $Preferred = if ($surface -lt 0.179) { [Windows.Media.Colors]::White } else { [Windows.Media.Colors]::Black }
    }
    return [Windows.Media.SolidColorBrush]::new($Preferred)
}

function Initialize-NetOpsBranding {
    $settings = $script:Ui.Configuration.Settings
    $controls = $script:Ui.Controls
    $resources = $script:Ui.Window.Resources
    $script:Ui.Window.Title = $settings.Application.Name
    $controls.AppTitle.Text = $settings.Application.Name
    if ($settings.Application.Company) {
        $controls.CompanyText.Text = $settings.Application.Company
        $controls.CompanyText.Visibility = 'Visible'
    }

    $theme = $settings.Theme
    $accent = [Windows.Media.ColorConverter]::ConvertFromString($theme.AccentColor)
    $highlight = [Windows.Media.ColorConverter]::ConvertFromString($theme.AccentBackgroundColor)
    $primary = [Windows.Media.ColorConverter]::ConvertFromString($theme.PrimaryActionColor)
    $workspace = [Windows.Media.ColorConverter]::ConvertFromString($theme.WorkspaceBackgroundColor)
    $white = [Windows.Media.Colors]::White
    $resources['AccentBrush'] = [Windows.Media.SolidColorBrush]::new($accent)
    $resources['AccentBackgroundBrush'] = [Windows.Media.SolidColorBrush]::new($highlight)
    $resources['PrimaryBrush'] = [Windows.Media.SolidColorBrush]::new($primary)
    $resources['WorkspaceBrush'] = [Windows.Media.SolidColorBrush]::new($workspace)
    $resources['PrimaryTextBrush'] = New-NetOpsReadableBrush $primary $white
    $resources['AccentOnWhiteBrush'] = New-NetOpsReadableBrush $white $accent
    $resources['AccentOnHighlightBrush'] = New-NetOpsReadableBrush $highlight $accent
    $resources['WorkspaceTextBrush'] = New-NetOpsReadableBrush $workspace $resources['TextBrush'].Color
    $resources['WorkspaceMutedBrush'] = New-NetOpsReadableBrush $workspace $resources['MutedBrush'].Color
    $resources['SelectedCellTextBrush'] = New-NetOpsReadableBrush $highlight $resources['TextBrush'].Color

    if ($settings.Branding.UseLocalLogo -and $settings.Branding.LogoPath) {
        $logo = [Windows.Media.Imaging.BitmapImage]::new()
        try {
            $stream = [IO.File]::OpenRead($settings.Branding.LogoPath)
            try {
                $logo.BeginInit()
                $logo.StreamSource = $stream
                $logo.CacheOption = 'OnLoad'
                $logo.DecodePixelWidth = 400
                $logo.EndInit()
                $logo.Freeze()
            }
            finally { $stream.Dispose() }
            $controls.CompanyLogo.Source = $logo
            $controls.CompanyLogo.Visibility = 'Visible'
            $controls.DefaultLogo.Visibility = 'Collapsed'
        }
        catch {
            $script:Ui.BrandingIssue = 'The configured logo could not be loaded. The default icon is in use.'
            Set-NetOpsStatus $script:Ui.BrandingIssue 'WarningBrush'
        }
    }
}

function Show-NetOpsResultDetail {
    $controls = $script:Ui.Controls
    $row = $controls.ResultGrid.SelectedItem
    if ($null -eq $row) {
        $controls.DetailsEmpty.Visibility = 'Visible'
        $controls.DetailsPanel.Visibility = 'Collapsed'
        $controls.DetailData.Clear()
        return
    }

    $controls.DetailsEmpty.Visibility = 'Collapsed'
    $controls.DetailsPanel.Visibility = 'Visible'
    $controls.DetailCheck.Text = $row.Check
    $controls.DetailTarget.Text = $row.Target
    $controls.DetailTarget.Visibility = if ($row.Target) { 'Visible' } else { 'Collapsed' }
    $controls.DetailOutcome.Text = $row.Outcome
    $brush = switch ($row.Outcome) {
        { $_ -in 'Success', 'Hop reply' } { 'SuccessBrush' }
        { $_ -in 'No reply', 'Partial replies', 'Timed out', 'Unavailable' } { 'WarningBrush' }
        { $_ -in 'Error', 'Failed', 'Refused', 'Unreachable' } { 'ErrorBrush' }
        default { 'MutedBrush' }
    }
    $controls.DetailOutcome.Foreground = $script:Ui.Window.FindResource($brush)
    $controls.DetailMessage.Text = $row.Detail
    $controls.DetailData.Text = if (@($row.Data.PSObject.Properties).Count -gt 0) {
        ConvertTo-Json -InputObject $row.Data -Depth 14
    }
    else { '' }
    $controls.DetailData.Visibility = if ($controls.DetailData.Text) { 'Visible' } else { 'Collapsed' }
    $controls.DetailData.ScrollToHome()
}

function Update-NetOpsResultGrid {
    $controls = $script:Ui.Controls
    $record = $script:Ui.Displayed
    $count = if ($record) { $record.Results.Count } else { 0 }
    $controls.ResultCount.Text = if ($count -eq 1) { '1 result' } elseif ($count -gt 1) { "$count results" } else { '' }
    $controls.ResultsEmpty.Visibility = if ($count) { 'Collapsed' } else { 'Visible' }
    if ($count) {
        if ($null -eq $controls.ResultGrid.SelectedItem) { $controls.ResultGrid.SelectedIndex = 0 }
        return
    }

    if ($record -and $record.State -eq 'Running') {
        $controls.EmptyTitle.Text = 'Diagnostic running'
        $controls.EmptyHint.Text = 'Results will appear as the worker returns them.'
    }
    elseif ($script:Ui.Page -eq 'Reports') {
        $controls.EmptyTitle.Text = 'No session results'
        $controls.EmptyHint.Text = 'Run a diagnostic to build a report.'
    }
    else {
        $controls.EmptyTitle.Text = 'No results yet'
        $controls.EmptyHint.Text = if ($script:Ui.Page -eq 'Home') {
            'Run a quick check to see the results here.'
        }
        else { 'Run this diagnostic to see the results here.' }
    }
}

function Show-NetOpsResultGrid {
    $controls = $script:Ui.Controls
    $record = switch ($script:Ui.Page) {
        'Home' { $script:Ui.Latest['QuickCheck'] }
        'Reports' { $controls.HistoryList.SelectedItem }
        default {
            if ($controls.ToolList.SelectedItem) { $script:Ui.Latest[$controls.ToolList.SelectedItem.Id] }
        }
    }
    $script:Ui.Displayed = $record
    $items = if ($record) { ,$record.Results }
    if (-not [object]::ReferenceEquals($controls.ResultGrid.ItemsSource, $items)) {
        $controls.ResultGrid.ItemsSource = $items
    }
    $controls.ResultTitle.Text = if ($script:Ui.Page -eq 'Reports' -and $record) { $record.Title } else { 'Results' }
    Update-NetOpsResultGrid
}

function Clear-NetOpsInputError {
    $script:Ui.Controls.InputError.Visibility = 'Collapsed'
}

function Select-NetOpsTool {
    $controls = $script:Ui.Controls
    $tool = $controls.ToolList.SelectedItem
    if (-not $tool) { return }

    if ($script:Ui.SelectedTool) {
        $script:Ui.ToolInputs[$script:Ui.SelectedTool] = @{ Target = $controls.TargetInput.Text; Port = $controls.PortInput.Text }
    }
    $script:Ui.SelectedTool = $tool.Id
    $script:Ui.LastTool[$tool.Page] = $tool.Id
    $stored = $script:Ui.ToolInputs[$tool.Id]
    $controls.ToolTitle.Text = $tool.Name
    $controls.ToolDescription.Text = $tool.Description
    $controls.InputsPanel.Visibility = if ($tool.Input) { 'Visible' } else { 'Collapsed' }
    $controls.PortPanel.Visibility = if ($tool.Input -eq 'Tcp') { 'Visible' } else { 'Collapsed' }
    $controls.TargetLabel.Content = if ($tool.Input -eq 'Dns') { 'DNS name (optional)' } else { 'Hostname or IP address' }
    $controls.TargetInput.Text = if ($stored) { $stored.Target } else { '' }
    $controls.PortInput.Text = if ($stored) { $stored.Port } else { '443' }
    Clear-NetOpsInputError
    Show-NetOpsResultGrid
}

function Show-NetOpsPage {
    param([string]$Page, [string]$ToolId)

    $controls = $script:Ui.Controls
    $script:Ui.Page = $Page
    $isTool = $Page -in 'Connectivity', 'Local'
    $isReports = $Page -eq 'Reports'

    $copy = switch ($Page) {
        'Home' { 'Network diagnostics', '' }
        'Connectivity' { 'Connectivity', 'Test DNS resolution, endpoint reachability, and network paths.' }
        'Local' { 'Local Network', 'Inspect adapters, addresses, routes, and current connections.' }
        'Reports' { 'Reports', 'Review runs from this session and export their results.' }
        'About' { 'About / Support', 'View runtime information, local files, and diagnostic endpoints.' }
    }
    $controls.PageTitle.Text, $controls.PageSubtitle.Text = $copy
    $controls.PageSubtitle.Visibility = if ($controls.PageSubtitle.Text) { 'Visible' } else { 'Collapsed' }
    $controls.HomePanel.Visibility = if ($Page -eq 'Home') { 'Visible' } else { 'Collapsed' }
    $controls.ToolRail.Visibility = if ($isTool) { 'Visible' } else { 'Collapsed' }
    $controls.RunPanel.Visibility = if ($isTool) { 'Visible' } else { 'Collapsed' }
    $controls.HistoryRail.Visibility = if ($isReports) { 'Visible' } else { 'Collapsed' }
    $controls.ExportPanel.Visibility = if ($isReports) { 'Visible' } else { 'Collapsed' }
    $controls.WorkPanel.Visibility = if ($Page -eq 'About') { 'Collapsed' } else { 'Visible' }
    $controls.SupportPanel.Visibility = if ($Page -eq 'About') { 'Visible' } else { 'Collapsed' }
    $controls.RailColumn.Width = if ($isTool -or $isReports) { [Windows.GridLength]::new(222) } else { [Windows.GridLength]::new(0) }

    foreach ($name in 'Home', 'Connectivity', 'Local', 'Reports') {
        $controls["$($name)Nav"].IsChecked = $name -eq $Page
    }
    if ($isTool) {
        $options = @($script:Ui.Tools | Where-Object Page -eq $Page)
        if ($script:Ui.ToolListPage -ne $Page) {
            $script:Ui.ToolListPage = $Page
            $controls.ToolList.ItemsSource = $options
        }
        $id = if ($ToolId) { $ToolId } elseif ($script:Ui.LastTool.ContainsKey($Page)) { $script:Ui.LastTool[$Page] } else { $options[0].Id }
        $controls.ToolList.SelectedItem = $options | Where-Object Id -eq $id
    }

    if ($isReports -and $null -eq $controls.HistoryList.SelectedItem -and $script:Ui.History.Count -gt 0) {
        $controls.HistoryList.SelectedIndex = 0
    }
    if ($Page -ne 'About') { Show-NetOpsResultGrid }
}

function Update-NetOpsRunState {
    $controls = $script:Ui.Controls
    $busy = $null -ne $script:Ui.Active
    $controls.RunButton.IsEnabled = -not $busy
    $controls.QuickCheckButton.IsEnabled = -not $busy
    $controls.CancelButton.Visibility = if ($busy) { 'Visible' } else { 'Collapsed' }
    $controls.CancelButton.IsEnabled = $busy -and -not $script:Ui.Active.StopReason
    $controls.RunProgress.Visibility = if ($busy) { 'Visible' } else { 'Collapsed' }
    $controls.RunProgress.IsIndeterminate = $busy
    $controls.EmptyHistory.Visibility = if ($script:Ui.History.Count) { 'Collapsed' } else { 'Visible' }
    $controls.ExportPanel.IsEnabled = $script:Ui.History.Count -gt 0
    $controls.ClearHistoryButton.IsEnabled = -not $busy -and $script:Ui.History.Count -gt 0
}

function Start-NetOpsDiagnostic {
    param([string]$ToolId)

    if ($script:Ui.Active) { return }

    $controls = $script:Ui.Controls
    Clear-NetOpsInputError
    try {
        $request = New-NetOpsRequest -ToolId $ToolId -Target $controls.TargetInput.Text -Port $controls.PortInput.Text
    }
    catch {
        $controls.InputError.Text = $_.Exception.Message
        $controls.InputError.Visibility = 'Visible'
        if ($_.Exception.Message -match '^Enter a TCP port') { [void]$controls.PortInput.Focus() }
        else { [void]$controls.TargetInput.Focus() }
        Set-NetOpsStatus $_.Exception.Message 'ErrorBrush'
        return
    }

    $tool = $script:Ui.Tools | Where-Object Id -eq $ToolId
    $started = [DateTimeOffset]::UtcNow
    try {
        $worker = Start-NetOpsRun -Request $request -Settings $script:Ui.Configuration.Settings.Diagnostics -DeadlineSeconds $tool.DeadlineSeconds
    }
    catch {
        $message = 'The background diagnostic could not be started. Check the PowerShell installation and file access.'
        $controls.InputError.Text = $message
        $controls.InputError.Visibility = 'Visible'
        Set-NetOpsStatus $message 'ErrorBrush'
        return
    }

    $record = [pscustomobject]@{
        RunId = [Guid]::NewGuid().ToString()
        ToolId = $tool.Id
        Title = $tool.Name
        StartedUtc = $started.ToString('o')
        StartedLocal = $started.ToLocalTime()
        DurationMs = 0
        Target = $request.Target
        Port = if ($request.Port) { $request.Port }
        State = 'Running'
        Results = $worker.Rows
        HistoryLabel = ''
    }
    $script:Ui.Active = $worker
    $script:Ui.ActiveRecord = $record
    $script:Ui.Latest[$tool.Id] = $record
    Show-NetOpsResultGrid
    Update-NetOpsRunState
    Set-NetOpsStatus "Running $($tool.Name)..."
    $script:Ui.Timer.Start()
}

function Request-NetOpsCancellation {
    if ($script:Ui.Active) {
        Stop-NetOpsRun -Run $script:Ui.Active -Reason 'Cancelled'
        Update-NetOpsRunState
        Set-NetOpsStatus "Stopping $($script:Ui.ActiveRecord.Title)..."
    }
}

function Complete-NetOpsDiagnostic {
    $worker = $script:Ui.Active
    $record = $script:Ui.ActiveRecord
    $script:Ui.Timer.Stop()
    try { Close-NetOpsRun $worker }
    catch { $worker.State = 'Failed' }
    finally {
        $script:Ui.Active = $null
        $script:Ui.ActiveRecord = $null
    }

    $record.State = $worker.State
    $record.DurationMs = $worker.Stopwatch.ElapsedMilliseconds
    $record.HistoryLabel = '{0:HH:mm:ss} | {1}' -f $record.StartedLocal, $record.State
    $script:Ui.History.Insert(0, $record)
    $logFailed = $false
    if ($script:Ui.LogPath) {
        try { Write-NetOpsSessionLog -Run $record -Path $script:Ui.LogPath }
        catch {
            $logFailed = $true
            $script:Ui.Controls.LoggingInfo.Text = "Could not write the session log at $($script:Ui.LogPath)."
        }
    }
    if ($script:Ui.Closing) {
        $script:Ui.Window.Close()
        return
    }

    Update-NetOpsRunState
    if ($script:Ui.Page -eq 'Reports' -and $null -eq $script:Ui.Controls.HistoryList.SelectedItem) {
        $script:Ui.Controls.HistoryList.SelectedIndex = 0
    }
    Show-NetOpsResultGrid
    $status = "$($record.Title) | $($record.State.ToLowerInvariant())."
    if ($logFailed) { $status += ' Session log could not be written.' }
    $brush = if ($logFailed -or $record.State -eq 'Timed out') { 'WarningBrush' }
        elseif ($record.State -eq 'Failed') { 'ErrorBrush' }
        else { 'MutedBrush' }
    Set-NetOpsStatus $status $brush
}

function Update-NetOpsDiagnostic {
    $worker = $script:Ui.Active
    if ($null -eq $worker) { return }

    Receive-NetOpsRun $worker
    if ($worker.State -ne 'Running') {
        Complete-NetOpsDiagnostic
        return
    }
    if ([object]::ReferenceEquals($script:Ui.Displayed, $script:Ui.ActiveRecord)) { Update-NetOpsResultGrid }

    $name = $script:Ui.ActiveRecord.Title
    $elapsed = [Math]::Floor($worker.Stopwatch.Elapsed.TotalSeconds)
    $message = if ($worker.TerminationError) { $worker.TerminationError }
        elseif ($worker.StopReason) { "Stopping $name..." }
        else { "Running $name ($($elapsed)s)..." }
    $script:Ui.Controls.CancelButton.IsEnabled = -not $worker.StopReason
    Set-NetOpsStatus $message
}

function Save-NetOpsSessionReport {
    param([ValidateSet('json', 'csv')][string]$Format)

    if ($script:Ui.History.Count -eq 0) { return }

    $dialog = [Microsoft.Win32.SaveFileDialog]::new()
    $dialog.Title = 'Export diagnostic session'
    $fileType = $Format.ToUpperInvariant()
    $dialog.Filter = "$fileType report (*.$Format)|*.$Format"
    $dialog.DefaultExt = ".$Format"
    $dialog.AddExtension = $true
    $dialog.OverwritePrompt = $true
    $dialog.FileName = 'NetOps-Session-{0:yyyyMMdd-HHmmss}' -f (Get-Date)
    if ($dialog.ShowDialog($script:Ui.Window) -ne $true) { return }

    if ([IO.Path]::GetExtension($dialog.FileName) -ne ".$Format") {
        $message = "Use the .$Format extension for this report."
        Set-NetOpsStatus $message 'ErrorBrush'
        [void][Windows.MessageBox]::Show($script:Ui.Window, $message, 'Export diagnostic session', 'OK', 'Error')
        return
    }
    try {
        Export-NetOpsReport -Runs @($script:Ui.History) -Path $dialog.FileName -Application $script:Ui.Configuration.Settings.Application
        Set-NetOpsStatus "Session exported to $($dialog.FileName)."
    }
    catch {
        Set-NetOpsStatus 'Could not export the diagnostic session.' 'ErrorBrush'
        $message = "Could not save the report to $($dialog.FileName). Check that the folder is writable and the file is available."
        [void][Windows.MessageBox]::Show($script:Ui.Window, $message, 'Export diagnostic session', 'OK', 'Error')
    }
}

function Open-NetOpsLocalItem {
    param([string]$Path, [string]$Missing)

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        Set-NetOpsStatus $Missing 'WarningBrush'
        return
    }
    try { Invoke-Item -LiteralPath $Path -ErrorAction Stop }
    catch { Set-NetOpsStatus "Windows could not open $Path." 'ErrorBrush' }
}

function Show-NetOpsWorkspace {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PackageRoot, [Parameter(Mandatory)]$Configuration)

    $stream = [IO.File]::OpenRead((Join-Path $PackageRoot 'Views\MainWindow.xaml'))
    try { $window = [Windows.Markup.XamlReader]::Load($stream) }
    finally { $stream.Dispose() }

    $controls = @{}
    foreach ($name in @(
        'AboutButton', 'DefaultLogo', 'CompanyLogo', 'AppTitle', 'CompanyText',
        'HomeNav', 'ConnectivityNav', 'LocalNav', 'ReportsNav', 'PageTitle', 'PageSubtitle', 'HomePanel',
        'QuickCheckButton', 'ShortcutTcp', 'ShortcutDns', 'ShortcutTrace', 'WorkPanel', 'RailColumn',
        'ToolRail', 'ToolList', 'HistoryRail', 'ClearHistoryButton', 'EmptyHistory', 'HistoryList',
        'RunPanel', 'RunButton', 'ToolTitle', 'ToolDescription', 'InputsPanel', 'TargetLabel', 'TargetInput',
        'PortPanel', 'PortInput', 'InputError', 'ExportPanel', 'ExportJsonButton', 'ExportCsvButton', 'ResultCount', 'ResultTitle', 'ResultGrid',
        'ResultsEmpty', 'EmptyTitle', 'EmptyHint', 'DetailsEmpty', 'DetailsPanel', 'DetailCheck',
        'DetailTarget', 'DetailOutcome', 'DetailMessage', 'DetailData', 'SupportPanel', 'ApplicationInfo',
        'ConfigInfo', 'LoggingInfo', 'OpenReadmeButton', 'OpenConfigButton', 'OpenLogsButton', 'ProbeInfo',
        'ComputerText', 'PowerShellText', 'CancelButton', 'RunProgress', 'StatusText'
    )) {
        $controls[$name] = $window.FindName($name)
        if ($null -eq $controls[$name]) { throw "The WPF view is missing the control '$name'." }
    }

    $settings = $Configuration.Settings
    $timer = [Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds(150)
    $script:Ui = @{
        Window = $window; Controls = $controls; Timer = $timer; Configuration = $Configuration
        PackageRoot = $PackageRoot; Page = ''; ToolListPage = ''; SelectedTool = ''; LastTool = @{}; ToolInputs = @{}
        Tools = @(Get-NetOpsTool); History = [Collections.ObjectModel.ObservableCollection[object]]::new()
        Latest = @{}; Displayed = $null; Active = $null; ActiveRecord = $null; Closing = $false
        BrandingIssue = ''; LogPath = ''
    }

    try {
        Initialize-NetOpsBranding
        $controls.HistoryList.ItemsSource = $script:Ui.History
        $controls.ComputerText.Text = [Environment]::MachineName
        $controls.PowerShellText.Text = "PowerShell $($PSVersionTable.PSVersion)"
        $controls.ApplicationInfo.Text = "$($settings.Application.Name) $($settings.Application.Version) | Windows desktop | $($controls.PowerShellText.Text)"
        $controls.ConfigInfo.Text = "Configuration file: $($Configuration.Path)"
        if ($script:Ui.BrandingIssue) { $controls.ConfigInfo.Text += [Environment]::NewLine + $script:Ui.BrandingIssue }
        if ($settings.Logging.Enabled) {
            $logFile = 'netops-{0:yyyyMMdd-HHmmss}-{1}.jsonl' -f (Get-Date), [Guid]::NewGuid().ToString('N').Substring(0, 8)
            $script:Ui.LogPath = Join-Path $settings.Logging.LocalLogFolder $logFile
            $controls.LoggingInfo.Text = "Session log: $($script:Ui.LogPath)"
        }
        else {
            $controls.LoggingInfo.Text = 'Session logging is disabled.'
            $controls.OpenLogsButton.IsEnabled = $false
        }

        $diagnostics = $settings.Diagnostics
        $services = ($diagnostics.PublicIpEndpoints | ForEach-Object { ([Uri]$_).Authority }) -join ', '
        $controls.ProbeInfo.Text = @(
            "DNS uses the Windows resolver for $($diagnostics.DnsTargets -join ', ') unless you enter a name."
            "Internet checks probe $($diagnostics.InternetIcmpAddress) over ICMP and $($diagnostics.InternetTcpHost) on TCP port $($diagnostics.InternetTcpPort)."
            "Public IP lookup sends an HTTPS request to $services. Each service sees the address used by the request."
            'Diagnostics run when you select Run. Logs and exports can include network addresses, interface details, and process names.'
        ) -join ([Environment]::NewLine * 2)

        foreach ($name in 'Home', 'Connectivity', 'Local', 'Reports') {
            $controls["$($name)Nav"].Add_Checked({
                param($navigation)
                if ($script:Ui.Page -ne $navigation.Tag) { Show-NetOpsPage $navigation.Tag }
            })
        }
        foreach ($name in 'ShortcutTcp', 'ShortcutDns', 'ShortcutTrace') {
            $controls[$name].Add_Click({
                param($shortcut)
                Show-NetOpsPage 'Connectivity' $shortcut.Tag
                [void]$script:Ui.Controls.TargetInput.Focus()
            })
        }

        $controls.AboutButton.Add_Click({ Show-NetOpsPage 'About' })
        $controls.ToolList.Add_SelectionChanged({ Select-NetOpsTool })
        $controls.HistoryList.Add_SelectionChanged({ Show-NetOpsResultGrid })
        $controls.ResultGrid.Add_SelectionChanged({ Show-NetOpsResultDetail })
        $controls.TargetInput.Add_TextChanged({ Clear-NetOpsInputError })
        $controls.PortInput.Add_TextChanged({ Clear-NetOpsInputError })
        $controls.QuickCheckButton.Add_Click({ Start-NetOpsDiagnostic 'QuickCheck' })
        $controls.RunButton.Add_Click({ Start-NetOpsDiagnostic $script:Ui.Controls.ToolList.SelectedItem.Id })
        $controls.CancelButton.Add_Click({ Request-NetOpsCancellation })
        $controls.ExportJsonButton.Add_Click({ Save-NetOpsSessionReport 'json' })
        $controls.ExportCsvButton.Add_Click({ Save-NetOpsSessionReport 'csv' })
        $controls.ClearHistoryButton.Add_Click({
            $script:Ui.Latest.Clear()
            $script:Ui.History.Clear()
            Show-NetOpsResultGrid
            Update-NetOpsRunState
            Set-NetOpsStatus 'Session history cleared.'
        })
        $controls.OpenConfigButton.Add_Click({
            Open-NetOpsLocalItem (Split-Path -Parent $script:Ui.Configuration.Path) 'The configuration folder is unavailable.'
        })
        $controls.OpenReadmeButton.Add_Click({
            Open-NetOpsLocalItem (Join-Path $script:Ui.PackageRoot 'README.md') 'The README is unavailable.'
        })
        $controls.OpenLogsButton.Add_Click({
            Open-NetOpsLocalItem $script:Ui.Configuration.Settings.Logging.LocalLogFolder 'The log folder is created after a diagnostic finishes.'
        })
        $timer.Add_Tick({ Update-NetOpsDiagnostic })
        $window.Add_Closing({
            if ($script:Ui.Active) {
                $args[1].Cancel = $true
                $script:Ui.Closing = $true
                Request-NetOpsCancellation
            }
        })

        Show-NetOpsPage 'Home'
        Update-NetOpsRunState
        [void]$window.ShowDialog()
    }
    finally {
        $timer.Stop()
        if ($script:Ui.Active) { Close-NetOpsRun $script:Ui.Active }
        $script:Ui = $null
    }
}

Export-ModuleMember -Function Show-NetOpsWorkspace
