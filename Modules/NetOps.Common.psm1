Set-StrictMode -Version 3.0

function ConvertTo-NetOpsTarget {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][AllowNull()][string]$Value,
        [switch]$DnsNameOnly
    )

    $text = ([string]$Value).Trim()
    if ($text.StartsWith('[') -and -not $text.EndsWith(']')) {
        throw 'Enter the hostname or IP address by itself.'
    }
    $address = $null
    if ([Net.IPAddress]::TryParse($text, [ref]$address)) {
        if ($DnsNameOnly) { throw 'Enter a DNS name for an A-record lookup.' }
        if ($address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork -and $text -ne $address.ToString()) {
            throw 'Use four decimal octets for an IPv4 address.'
        }
        if ($text.Contains('%') -and $text -notmatch '%[0-9]+$') {
            throw 'Use a numeric scope ID for a scoped IPv6 address.'
        }
        if ($address.Equals([Net.IPAddress]::Any) -or $address.Equals([Net.IPAddress]::IPv6Any) -or
            $address.Equals([Net.IPAddress]::Broadcast)) {
            throw 'Enter a specific destination address.'
        }
        return $address.ToString()
    }

    if (-not $text -or $text.Length -gt 254 -or $text -match '^[0-9.]+$') {
        throw 'Enter a valid DNS name or IP address.'
    }

    try {
        $idn = [Globalization.IdnMapping]::new()
        $idn.UseStd3AsciiRules = $true
        $name = $idn.GetAscii($text)
    }
    catch {
        throw 'Enter a valid DNS name or IP address.'
    }

    $labels = $name.TrimEnd('.') -split '\.'
    if ($name.TrimEnd('.').Length -gt 253 -or $name.EndsWith('..') -or
        ($labels -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$')) {
        throw 'Use DNS labels of 1 to 63 characters with letters, digits or interior hyphens.'
    }
    return $name.ToLowerInvariant()
}

function Resolve-NetOpsLocalPath {
    param([string]$Value, [string]$PackageRoot)

    $path = [Environment]::ExpandEnvironmentVariables($Value).Replace('/', '\')
    if ([IO.Path]::IsPathFullyQualified($path) -and $path -notmatch '^[A-Za-z]:\\') {
        throw 'Use a local drive path or a path relative to the application folder.'
    }
    if ([IO.Path]::IsPathRooted($path) -and -not [IO.Path]::IsPathFullyQualified($path)) {
        throw 'Use a fully qualified drive path or a relative path.'
    }
    try { return [IO.Path]::GetFullPath($path, $PackageRoot) }
    catch { throw 'The configuration contains an invalid file or folder path.' }
}

function Get-NetOpsConfigurationFile {
    param([string]$Path)

    try { $text = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop }
    catch { throw "Could not read the configuration file '$Path'. Check that it exists and is readable." }

    try { $config = ConvertFrom-Json -InputObject ([string]$text) -AsHashtable -NoEnumerate -ErrorAction Stop }
    catch { throw "The configuration file '$Path' contains invalid JSON." }
    if ($config -isnot [Collections.IDictionary]) {
        throw "The configuration file '$Path' must contain a JSON object."
    }
    return $config
}

function Get-NetOpsConfiguration {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PackageRoot)

    $PackageRoot = [IO.Path]::GetFullPath($PackageRoot)
    $examplePath = Join-Path $PackageRoot 'Config\config.example.json'
    $localPath = Join-Path $PackageRoot 'Config\config.local.json'
    $config = Get-NetOpsConfigurationFile $examplePath
    foreach ($section in 'Application', 'Branding', 'Theme', 'Diagnostics', 'Logging') {
        if ($config[$section] -isnot [Collections.IDictionary]) {
            throw "The example configuration must contain a '$section' object. Restore the supplied configuration at '$examplePath'."
        }
    }
    $activePath = $examplePath

    if (Test-Path -LiteralPath $localPath) {
        $activePath = $localPath
        try {
            $overrides = Get-NetOpsConfigurationFile $localPath
            foreach ($section in $overrides.Keys) {
                if (-not $config.Contains($section)) { throw "Unknown configuration section '$section'." }
                if ($overrides[$section] -isnot [Collections.IDictionary]) { throw "'$section' must be a JSON object." }
                foreach ($key in $overrides[$section].Keys) {
                    if (-not $config[$section].Contains($key)) { throw "Unknown configuration setting '$section.$key'." }
                    $config[$section][$key] = $overrides[$section][$key]
                }
            }
        }
        catch {
            throw "Could not load $activePath. $($_.Exception.Message)"
        }
    }

    try {
        foreach ($key in 'Name', 'Version', 'Company') {
            if ($config.Application[$key] -isnot [string] -or $config.Application[$key] -match '[\r\n\t]' -or
                $config.Application[$key].Length -gt 100) {
                throw "Application.$key must be a single line of up to 100 characters."
            }
            $config.Application[$key] = $config.Application[$key].Trim()
        }
        if (-not $config.Application.Name -or -not $config.Application.Version) {
            throw 'Application.Name and Application.Version are required.'
        }

        foreach ($key in $config.Theme.Keys) {
            if ($config.Theme[$key] -isnot [string] -or $config.Theme[$key] -cnotmatch '^#[0-9a-fA-F]{6}$') {
                throw "Theme.$key must be an RGB color such as #2563EB."
            }
        }
        if ($config.Branding.UseLocalLogo -isnot [bool] -or $config.Branding.LogoPath -isnot [string]) {
            throw 'Branding.UseLocalLogo must be a boolean and Branding.LogoPath must be a string.'
        }
        if ($config.Branding.UseLocalLogo -and $config.Branding.LogoPath.Trim()) {
            $config.Branding.LogoPath = Resolve-NetOpsLocalPath $config.Branding.LogoPath $PackageRoot
        }
        if ($config.Logging.Enabled -isnot [bool] -or $config.Logging.LocalLogFolder -isnot [string] -or
            ($config.Logging.Enabled -and -not $config.Logging.LocalLogFolder.Trim())) {
            throw 'Logging requires a boolean Enabled setting and a folder path when enabled.'
        }
        if ($config.Logging.Enabled) {
            $config.Logging.LocalLogFolder = Resolve-NetOpsLocalPath $config.Logging.LocalLogFolder $PackageRoot
        }

        $diagnostics = $config.Diagnostics
        $ranges = @{
            PingTimeoutMs = @(200, 2000)
            TraceTimeoutMs = @(200, 1000)
            ConnectTimeoutSeconds = @(1, 15)
            PublicIpTimeoutSeconds = @(1, 10)
            InternetTcpPort = @(1, 65535)
        }
        foreach ($key in $ranges.Keys) {
            $value = $diagnostics[$key]
            $minimum, $maximum = $ranges[$key]
            if (($value -isnot [int] -and $value -isnot [long]) -or $value -lt $minimum -or $value -gt $maximum) {
                throw "Diagnostics.$key must be an integer from $minimum to $maximum."
            }
        }

        if ($diagnostics.DnsTargets -isnot [array] -or $diagnostics.DnsTargets.Count -notin (1..5)) {
            throw 'Diagnostics.DnsTargets must contain one to five DNS names.'
        }
        $diagnostics.DnsTargets = @(foreach ($name in $diagnostics.DnsTargets) {
            if ($name -isnot [string]) { throw 'Each entry in Diagnostics.DnsTargets must be a DNS name.' }
            ConvertTo-NetOpsTarget $name -DnsNameOnly
        })
        $diagnostics.InternetIcmpAddress = ConvertTo-NetOpsTarget $diagnostics.InternetIcmpAddress
        $ip = $null
        if (-not [Net.IPAddress]::TryParse($diagnostics.InternetIcmpAddress, [ref]$ip)) {
            throw 'Diagnostics.InternetIcmpAddress must be an IPv4 or IPv6 address.'
        }
        $diagnostics.InternetTcpHost = ConvertTo-NetOpsTarget $diagnostics.InternetTcpHost

        if ($diagnostics.PublicIpEndpoints -isnot [array] -or $diagnostics.PublicIpEndpoints.Count -notin (1..3)) {
            throw 'Diagnostics.PublicIpEndpoints must contain one to three HTTPS URLs.'
        }
        foreach ($endpoint in $diagnostics.PublicIpEndpoints) {
            $uri = $null
            if ($endpoint -isnot [string] -or $endpoint.Length -gt 300 -or
                -not [Uri]::TryCreate($endpoint, [UriKind]::Absolute, [ref]$uri) -or
                $uri.Scheme -ne 'https' -or -not $uri.Host -or $uri.UserInfo -or $uri.Fragment) {
                throw 'Each public IP endpoint must be an HTTPS URL of up to 300 characters without credentials or a fragment.'
            }
        }
    }
    catch {
        throw "Invalid configuration in $activePath. $($_.Exception.Message)"
    }

    return [pscustomobject]@{ Settings = $config; Path = $activePath }
}

function Get-NetOpsTool {
    $tools = @(
        @('QuickCheck', 'Home', 'Quick check', 'Inspect the active adapter, IPv4 address, gateway, DNS, ICMP and TCP connectivity.', '', 85),
        @('Gateway', 'Connectivity', 'Default gateway', 'Send four ICMP probes to the preferred IPv4 default gateway.', '', 25),
        @('Dns', 'Connectivity', 'DNS lookup', 'Query A records through Windows DNS. Leave the name blank to test the configured targets.', 'Dns', 60),
        @('Internet', 'Connectivity', 'Internet connectivity', 'Test the configured public ICMP and TCP endpoints independently.', '', 45),
        @('Tcp', 'Connectivity', 'TCP port', 'Try a TCP connection to a hostname or IP address and port.', 'Tcp', 35),
        @('Trace', 'Connectivity', 'Traceroute', 'Trace an IPv4 or IPv6 route with three ICMP probes per hop and up to 20 hops.', 'Host', 80),
        @('PublicIp', 'Connectivity', 'Public IP address', 'Ask the configured HTTPS services for the address they see for this connection.', '', 40),
        @('Adapters', 'Local', 'Network adapters', 'Inspect interface status, hardware addresses and link speeds.', '', 30),
        @('Addresses', 'Local', 'Local IP addresses', 'List non-loopback IPv4 and IPv6 addresses with their prefixes and origin.', '', 30),
        @('Neighbors', 'Local', 'ARP table', 'Inspect the local IPv4 neighbor cache and address-to-MAC mappings.', '', 30),
        @('Routes', 'Local', 'Routing table', 'Inspect IPv4 and IPv6 destinations, next hops and metrics.', '', 30),
        @('Connections', 'Local', 'TCP connections', 'Inspect established TCP connections and their owning processes.', '', 30),
        @('Wifi', 'Local', 'Wi-Fi interfaces', 'Inspect wireless adapter state and Windows WLAN connection details.', '', 30),
        @('DnsServers', 'Local', 'Configured DNS servers', 'List DNS resolver addresses by interface and address family.', '', 30)
    )
    foreach ($tool in $tools) {
        [pscustomobject]@{
            Id = $tool[0]
            Page = $tool[1]
            Name = $tool[2]
            Description = $tool[3]
            Input = $tool[4]
            DeadlineSeconds = $tool[5]
        }
    }
}

function New-NetOpsRequest {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory diagnostic request.')]
    param([Parameter(Mandatory)][string]$ToolId, [string]$Target, [string]$Port)

    $tool = Get-NetOpsTool | Where-Object Id -eq $ToolId
    if (-not $tool) { throw 'Select an available diagnostic.' }

    $hostName = ''
    if ($tool.Input -in 'Host', 'Tcp') { $hostName = ConvertTo-NetOpsTarget $Target }
    if ($tool.Input -eq 'Dns' -and -not [string]::IsNullOrWhiteSpace($Target)) {
        $hostName = ConvertTo-NetOpsTarget $Target -DnsNameOnly
    }
    $portNumber = 0
    if ($tool.Input -eq 'Tcp' -and
        ($Port -notmatch '^\s*[0-9]{1,5}\s*$' -or -not [int]::TryParse($Port, [ref]$portNumber) -or
         $portNumber -lt 1 -or $portNumber -gt 65535)) {
        throw 'Enter a TCP port from 1 to 65535.'
    }

    return @{ ToolId = $tool.Id; Target = $hostName; Port = $portNumber }
}

Export-ModuleMember -Function ConvertTo-NetOpsTarget, Get-NetOpsConfiguration, Get-NetOpsTool, New-NetOpsRequest
