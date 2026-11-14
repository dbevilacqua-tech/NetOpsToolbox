[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Scope = 'Function', Target = '*-NetOpsRun', Justification = 'Controls the app-owned diagnostic worker process.')]
param()

Set-StrictMode -Version 3.0

function Start-NetOpsRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Request,
        [Parameter(Mandatory)][Collections.IDictionary]$Settings,
        [Parameter(Mandatory)][ValidateRange(1, 90)][int]$DeadlineSeconds
    )

    $encoding = [Text.UTF8Encoding]::new($false)
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Join-Path $PSHOME 'pwsh.exe'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardInputEncoding = $encoding
    $startInfo.StandardOutputEncoding = $encoding
    $startInfo.StandardErrorEncoding = $encoding
    foreach ($argument in '-NoLogo', '-NoProfile', '-NonInteractive', '-File', (Join-Path $PSScriptRoot 'Invoke-NetOpsWorker.ps1')) {
        $startInfo.ArgumentList.Add($argument)
    }

    $payload = @{ Request = $Request; Settings = $Settings } |
        ConvertTo-Json -Depth 8 -Compress -EscapeHandling EscapeNonAscii
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $started = $false
    try {
        $started = $process.Start()
        if (-not $started) { throw 'The diagnostic worker did not start.' }

        [pscustomobject]@{
            Process = $process
            Stopwatch = [Diagnostics.Stopwatch]::StartNew()
            DeadlineSeconds = $DeadlineSeconds
            InputTask = $process.StandardInput.WriteLineAsync($payload)
            OutputTask = $process.StandardOutput.ReadLineAsync()
            ErrorTask = $process.StandardError.ReadToEndAsync()
            Rows = [Collections.ObjectModel.ObservableCollection[object]]::new()
            StopReason = ''
            TerminationError = ''
            WorkerError = ''
            DoneSignal = $false
            State = 'Running'
        }
    }
    catch {
        try { if ($started -and -not $process.HasExited) { $process.Kill($true) } }
        finally { $process.Dispose() }
        throw
    }
}

function Stop-NetOpsRun {
    param(
        [Parameter(Mandatory)]$Run,
        [Parameter(Mandatory)][ValidateSet('Cancelled', 'Timed out', 'Failed')][string]$Reason
    )

    if ($Run.State -ne 'Running' -or $Run.Process.HasExited) { return }
    if (-not $Run.StopReason) { $Run.StopReason = $Reason }
    try {
        if (-not $Run.Process.HasExited) { $Run.Process.Kill($true) }
        $Run.TerminationError = ''
    }
    catch {
        if (-not $Run.Process.HasExited) { $Run.TerminationError = 'Waiting for Windows to stop the diagnostic worker.' }
    }
}

function Receive-NetOpsRun {
    param([Parameter(Mandatory)]$Run)

    if ($Run.State -ne 'Running') { return }
    if ($Run.StopReason -and -not $Run.Process.HasExited) {
        Stop-NetOpsRun -Run $Run -Reason $Run.StopReason
    }
    elseif (-not $Run.Process.HasExited -and $Run.Stopwatch.Elapsed.TotalSeconds -ge $Run.DeadlineSeconds) {
        Stop-NetOpsRun -Run $Run -Reason 'Timed out'
    }

    if ($null -ne $Run.InputTask -and $Run.InputTask.IsCompleted) {
        try {
            [void]$Run.InputTask.GetAwaiter().GetResult()
            $Run.Process.StandardInput.Close()
        }
        catch {
            if (-not $Run.StopReason) {
                $Run.WorkerError = 'The worker could not receive the diagnostic request.'
                Stop-NetOpsRun -Run $Run -Reason 'Failed'
            }
        }
        $Run.InputTask = $null
    }

    # Process a bounded batch on each dispatcher tick so large inventories yield to the UI.
    for ($i = 0; $i -lt 200 -and $null -ne $Run.OutputTask -and $Run.OutputTask.IsCompleted; $i++) {
        try {
            $line = $Run.OutputTask.GetAwaiter().GetResult()
            if ($null -eq $line) {
                $Run.OutputTask = $null
                break
            }
            $Run.OutputTask = $Run.Process.StandardOutput.ReadLineAsync()
            if (-not $line.Trim()) { continue }

            $message = ConvertFrom-Json -InputObject $line -ErrorAction Stop
            switch ($message.Type) {
                'Result' { $Run.Rows.Add($message.Row) }
                'Done' { $Run.DoneSignal = $true }
                'Error' { $Run.WorkerError = $message.ErrorId }
                default { throw 'Unexpected worker message.' }
            }
        }
        catch {
            $Run.OutputTask = $null
            if (-not $Run.StopReason) {
                $Run.WorkerError = 'The worker output could not be read.'
                Stop-NetOpsRun -Run $Run -Reason 'Failed'
            }
        }
    }

    if (-not $Run.Process.HasExited -or $null -ne $Run.OutputTask -or -not $Run.ErrorTask.IsCompleted) { return }
    try { $workerStderr = $Run.ErrorTask.GetAwaiter().GetResult() }
    catch { $workerStderr = '' }
    if ($workerStderr -and -not $Run.WorkerError -and -not $Run.DoneSignal) {
        $Run.WorkerError = 'Worker standard error reported a startup or runtime failure.'
    }
    $state = if ($Run.Process.ExitCode -eq 0 -and $Run.DoneSignal -and -not $Run.WorkerError -and $Run.Rows.Count -gt 0) {
        'Completed'
    }
    elseif ($Run.StopReason) { $Run.StopReason }
    else { 'Failed' }

    if ($state -ne 'Completed') {
        $detail = switch ($state) {
            'Cancelled' { 'The diagnostic was cancelled. Results already received are available.' }
            'Timed out' { "The diagnostic reached its $($Run.DeadlineSeconds)-second run limit. Results already received are available." }
            'Failed' { 'The diagnostic worker stopped before it returned a complete result.' }
        }
        $Run.Rows.Add([pscustomobject]@{
            Check = 'Run status'
            Target = ''
            Outcome = $state
            Detail = $detail
            Data = [pscustomobject]@{ ExitCode = $Run.Process.ExitCode; ErrorId = $Run.WorkerError }
        })
    }
    $Run.Stopwatch.Stop()
    $Run.State = $state
}

function Close-NetOpsRun {
    param([Parameter(Mandatory)]$Run)

    try {
        if (-not $Run.Process.HasExited) {
            Stop-NetOpsRun -Run $Run -Reason 'Cancelled'
            [void]$Run.Process.WaitForExit(2000)
        }
        $Run.Process.StandardOutput.Dispose()
        $Run.Process.StandardError.Dispose()
        $Run.Process.StandardInput.Dispose()
    }
    finally { $Run.Process.Dispose() }
}

Export-ModuleMember -Function Start-NetOpsRun, Stop-NetOpsRun, Receive-NetOpsRun, Close-NetOpsRun
