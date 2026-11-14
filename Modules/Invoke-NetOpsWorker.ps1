#Requires -Version 7.4
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'The console streams are the UTF-8 worker protocol.')]
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

try {
    Import-Module (Join-Path $PSScriptRoot 'NetOps.Common.psm1') -ErrorAction Stop
    Import-Module (Join-Path $PSScriptRoot 'NetOps.Diagnostics.psm1') -ErrorAction Stop
    $payload = [Console]::ReadLine() | ConvertFrom-Json -AsHashtable
    $request = New-NetOpsRequest -ToolId $payload.Request.ToolId -Target $payload.Request.Target -Port $payload.Request.Port
    $tool = Get-NetOpsTool | Where-Object Id -eq $request.ToolId
    Invoke-NetOpsDiagnostic -Request $request -Settings $payload.Settings -Name $tool.Name | ForEach-Object {
        $message = @{ Type = 'Result'; Row = $_ } | ConvertTo-Json -Depth 14 -Compress -EscapeHandling EscapeNonAscii
        [Console]::WriteLine($message)
    }
    [Console]::WriteLine('{"Type":"Done"}')
}
catch {
    $message = @{ Type = 'Error'; ErrorId = $_.FullyQualifiedErrorId } |
        ConvertTo-Json -Compress -EscapeHandling EscapeNonAscii
    [Console]::WriteLine($message)
    exit 1
}
