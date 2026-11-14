#Requires -Version 7.4
<#
.SYNOPSIS
Opens the NetOps Toolbox diagnostics workspace on Windows.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

if (-not $IsWindows) {
    throw 'NetOps Toolbox requires Windows with a desktop session.'
}
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    throw 'The workspace requires STA. Run pwsh -NoProfile -STA -File .\NetOpsToolbox.ps1.'
}

$startupMessage = 'Could not load the Windows desktop components. Run the launcher in PowerShell 7 on a Windows desktop.'
try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    $startupMessage = 'Could not load the application files. Check that the complete package was extracted.'
    Import-Module (Join-Path $PSScriptRoot 'Modules\NetOps.Common.psm1') -Force
    $startupMessage = ''
    $configuration = Get-NetOpsConfiguration -PackageRoot $PSScriptRoot
    $startupMessage = 'Could not open the diagnostics window. Check that the complete package was extracted.'
    Import-Module (Join-Path $PSScriptRoot 'Modules\NetOps.Workspace.psm1') -Force
    Show-NetOpsWorkspace -PackageRoot $PSScriptRoot -Configuration $configuration
}
catch {
    $message = if ($startupMessage) { $startupMessage } else { $_.Exception.Message }
    if ('System.Windows.MessageBox' -as [type]) {
        [void][System.Windows.MessageBox]::Show($message, 'NetOps Toolbox', 'OK', 'Error')
    }
    throw [InvalidOperationException]::new($message, $_.Exception)
}
