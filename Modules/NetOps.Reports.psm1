Set-StrictMode -Version 3.0

function ConvertTo-NetOpsReportRun {
    param([Parameter(Mandatory)]$Run)

    [ordered]@{
        RunId = $Run.RunId
        Diagnostic = $Run.ToolId
        Name = $Run.Title
        StartedUtc = $Run.StartedUtc
        DurationMs = $Run.DurationMs
        State = $Run.State
        RequestedTarget = $Run.Target
        RequestedPort = $Run.Port
        Results = @($Run.Results)
    }
}

function Write-NetOpsSessionLog {
    param(
        [Parameter(Mandatory)]$Run,
        [Parameter(Mandatory)][string]$Path
    )

    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    $entry = ConvertTo-NetOpsReportRun $Run | ConvertTo-Json -Depth 16 -Compress
    [IO.File]::AppendAllText($Path, $entry + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
}

function Protect-NetOpsCsvCell {
    param([AllowNull()][string]$Value)

    if ($Value -match '^[\t\r\n]|^[\s\p{Cf}]*[=+\-@\uFF1D\uFF0B\uFF0D\uFF20]') { return "'" + $Value }
    return $Value
}

function Export-NetOpsReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Runs,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][Collections.IDictionary]$Application
    )

    $extension = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($extension -notin '.json', '.csv') { throw 'Choose a .json or .csv file.' }
    $directory = [IO.Path]::GetDirectoryName($Path)
    $temporary = [IO.Path]::Combine($directory, ".netops-$([Guid]::NewGuid()).tmp")
    try {
        if ($extension -eq '.json') {
            $report = [ordered]@{
                SchemaVersion = 1
                Application = [ordered]@{ Name = $Application.Name; Version = $Application.Version; Company = $Application.Company }
                ExportedUtc = [DateTimeOffset]::UtcNow.ToString('o')
                Runs = @(foreach ($run in $Runs) { ConvertTo-NetOpsReportRun $run })
            }
            $report | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $temporary -Encoding utf8NoBOM -ErrorAction Stop
        }
        else {
            & {
                foreach ($run in $Runs) {
                    foreach ($row in $run.Results) {
                        [pscustomobject]@{
                            RunId = $run.RunId
                            StartedUtc = $run.StartedUtc
                            DurationMs = $run.DurationMs
                            Diagnostic = $run.ToolId
                            RunState = $run.State
                            Check = Protect-NetOpsCsvCell $row.Check
                            Target = Protect-NetOpsCsvCell $row.Target
                            Outcome = $row.Outcome
                            Detail = Protect-NetOpsCsvCell $row.Detail
                            DataJson = ConvertTo-Json -InputObject $row.Data -Depth 14 -Compress
                        }
                    }
                }
            } | Export-Csv -LiteralPath $temporary -Encoding utf8BOM -NoTypeInformation -ErrorAction Stop
        }
        [IO.File]::Move($temporary, $Path, $true)
    }
    finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

Export-ModuleMember -Function Write-NetOpsSessionLog, Export-NetOpsReport
