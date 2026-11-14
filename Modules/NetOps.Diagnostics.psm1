[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Scope = 'Function', Target = 'New-NetOps*', Justification = 'Creates in-memory result objects.')]
param()

Set-StrictMode -Version 3.0

function New-NetOpsResult {
    param(
        [string]$Check,
        [string]$Target,
        [string]$Outcome,
        [string]$Detail,
        [Collections.IDictionary]$Data = @{}
    )
    [pscustomobject]@{ Check = $Check; Target = $Target; Outcome = $Outcome; Detail = $Detail; Data = $Data }
}

function New-NetOpsProviderError {
    param([string]$Check, [string]$Target, [Management.Automation.ErrorRecord]$Record)

    $category = [string]$Record.CategoryInfo.Category
    $outcome = if ($category -in 'PermissionDenied', 'SecurityError', 'ResourceUnavailable', 'NotInstalled' -or
        $Record.Exception -is [Management.Automation.CommandNotFoundException] -or
        $Record.FullyQualifiedErrorId -match 'AccessDenied|MI RESULT 2\b|HRESULT 0x80070005' -or
        $Record.Exception.GetBaseException() -is [UnauthorizedAccessException]) {
        'Unavailable'
    }
    else { 'Error' }
    New-NetOpsResult $Check $Target $outcome 'Windows could not read this information with the current account or services.' @{
        ErrorId = $Record.FullyQualifiedErrorId
        Category = $category
    }
}

function Get-NetOpsTargetAddress {
    param([string]$Target, [Threading.CancellationToken]$Token)

    $ip = $null
    if ([Net.IPAddress]::TryParse($Target, [ref]$ip)) { return $ip }
    [Net.Dns]::GetHostAddressesAsync($Target, $Token).GetAwaiter().GetResult()
}

function Get-NetOpsPingSample {
    param([Net.NetworkInformation.Ping]$Ping, [Net.IPAddress]$Address, [int]$TimeoutMs, [int]$Ttl)

    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        $reply = $Ping.Send($Address, $TimeoutMs, [byte[]]::new(32), [Net.NetworkInformation.PingOptions]::new($Ttl, $false))
        $outcome = switch -Regex ([string]$reply.Status) {
            '^Success$' { 'Success'; break }
            '^(TtlExpired|TimeExceeded)$' { 'Hop reply'; break }
            '^TimedOut$' { 'No reply'; break }
            '^Destination.*Unreachable$' { 'Unreachable'; break }
            default { 'ICMP error' }
        }
        return [ordered]@{
            Outcome = $outcome
            IcmpStatus = [string]$reply.Status
            ReplyAddress = if ($outcome -in 'Success', 'Hop reply') { [string]$reply.Address } else { '' }
            RoundTripMs = if ($outcome -eq 'Success') { $reply.RoundtripTime }
            ElapsedMs = $clock.ElapsedMilliseconds
        }
    }
    catch {
        return [ordered]@{
            Outcome = 'Error'
            IcmpStatus = $_.Exception.GetBaseException().GetType().Name
            ReplyAddress = ''
            RoundTripMs = $null
            ElapsedMs = $clock.ElapsedMilliseconds
        }
    }
}

function Invoke-NetOpsEcho {
    param([string]$Check, [Net.IPAddress]$Address, [int]$Count, [int]$TimeoutMs, [hashtable]$Context = @{})

    $ping = [Net.NetworkInformation.Ping]::new()
    try {
        $samples = @(for ($i = 0; $i -lt $Count; $i++) { Get-NetOpsPingSample $ping $Address $TimeoutMs 128 })
    }
    finally { $ping.Dispose() }

    $replies = @($samples | Where-Object Outcome -eq 'Success')
    $codes = ($samples.IcmpStatus | Select-Object -Unique) -join ', '
    $outcome = 'No reply'
    $average = $null
    if ($replies.Count -gt 0) {
        $outcome = if ($replies.Count -eq $samples.Count) { 'Success' } else { 'Partial replies' }
        $average = [Math]::Round(($replies.RoundTripMs | Measure-Object -Average).Average, 1)
        $detail = "$($replies.Count) of $Count ICMP echo replies received. Average round trip $average ms."
    }
    elseif ($samples.Outcome -contains 'Unreachable') {
        $outcome = 'Unreachable'
        $detail = "No echo replies. ICMP returned an unreachable indication ($codes)."
    }
    elseif (@($samples | Where-Object Outcome -ne 'No reply').Count -gt 0) {
        $outcome = 'Error'
        $detail = "No echo replies. The probe returned $codes."
    }
    else {
        $detail = "No ICMP echo replies within $TimeoutMs ms per probe. ICMP may be filtered or unanswered."
    }
    $Context.Samples = $samples
    $Context.Sent = $Count
    $Context.Received = $replies.Count
    $Context.AverageRoundTripMs = $average
    New-NetOpsResult $Check $Address.ToString() $outcome $detail $Context
}

function Invoke-NetOpsGateway {
    param([int]$Count, [int]$TimeoutMs)

    $check = 'Default gateway'
    try {
        $metrics = @{}
        Get-NetIPInterface -AddressFamily IPv4 -PolicyStore ActiveStore -ErrorAction Stop | ForEach-Object {
            $metrics[[int]$_.InterfaceIndex] = $_
        }
        $routes = @(Get-NetRoute -AddressFamily IPv4 -PolicyStore ActiveStore -ErrorAction Stop |
            Where-Object {
                $_.DestinationPrefix -eq '0.0.0.0/0' -and
                    $metrics.ContainsKey([int]$_.InterfaceIndex) -and
                    [string]$metrics[[int]$_.InterfaceIndex].ConnectionState -eq 'Connected'
            } | Sort-Object -Property @{ Expression = { $_.RouteMetric + $metrics[[int]$_.InterfaceIndex].InterfaceMetric } }, InterfaceIndex)
        if ($routes.Count -eq 0) {
            return New-NetOpsResult $check '' 'No data' 'No active IPv4 default route was found.'
        }
        $route = $routes[0]
        $context = @{
            Interface = $route.InterfaceAlias
            InterfaceIndex = $route.InterfaceIndex
            RouteMetric = $route.RouteMetric
            InterfaceMetric = $metrics[[int]$route.InterfaceIndex].InterfaceMetric
            DefaultRoutes = $routes.Count
        }
        if ($route.NextHop -eq '0.0.0.0') {
            return New-NetOpsResult $check $route.InterfaceAlias 'Skipped' 'The preferred default route is on-link and has no separate gateway address.' $context
        }
        Invoke-NetOpsEcho $check ([Net.IPAddress]::Parse($route.NextHop)) $Count $TimeoutMs $context
    }
    catch { New-NetOpsProviderError $check '' $_ }
}

function Invoke-NetOpsDnsLookup {
    param([string[]]$Names)

    foreach ($name in $Names) {
        try {
            $records = @(Resolve-DnsName -Name $name -Type A -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction Stop |
                Where-Object Type -eq 'A' | Select-Object Name, IPAddress, TTL)
            if ($records.Count -gt 0) {
                New-NetOpsResult 'DNS A lookup' $name 'Success' ($records.IPAddress -join ', ') @{ Records = $records }
            }
            else {
                New-NetOpsResult 'DNS A lookup' $name 'No records' 'This query returned no IPv4 A records.'
            }
        }
        catch {
            $outcome, $detail = switch -Regex ($_.FullyQualifiedErrorId) {
                '^DNS_ERROR_RCODE_NAME_ERROR' { 'Name not found', 'The DNS resolver reported that this name does not exist.'; break }
                '^DNS_INFO_NO_RECORDS' { 'No records', 'The DNS resolver returned no IPv4 A records.'; break }
                'TIMEOUT' { 'Timed out', 'Windows reported that the DNS query timed out.'; break }
                default { 'Error', 'Windows could not complete the DNS query.' }
            }
            New-NetOpsResult 'DNS A lookup' $name $outcome $detail @{ ErrorId = $_.FullyQualifiedErrorId }
        }
    }
}

function Invoke-NetOpsTcp {
    param([string]$Target, [int]$Port, [int]$TimeoutSeconds)

    $check = 'TCP port'
    $displayTarget = if ($Target.Contains(':')) { "[$Target]:$Port" } else { "$($Target):$Port" }
    $data = @{ Host = $Target; Port = $Port; Addresses = @(); RemoteAddress = '' }
    $timer = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSeconds))
    $client = $null
    $stage = 'Name resolution'
    try {
        [Net.IPAddress[]]$addresses = @(Get-NetOpsTargetAddress $Target $timer.Token)
        $data.Addresses = @($addresses | ForEach-Object ToString)
        if ($addresses.Length -eq 0) {
            return New-NetOpsResult $check $displayTarget 'Name not found' 'The system resolver returned no addresses.' $data
        }
        $stage = 'TCP connection'
        $client = [Net.Sockets.TcpClient]::new()
        $client.ConnectAsync($addresses, $Port, $timer.Token).GetAwaiter().GetResult()
        $remoteAddress = $client.Client.RemoteEndPoint.Address
        if ($remoteAddress.IsIPv4MappedToIPv6) { $remoteAddress = $remoteAddress.MapToIPv4() }
        $data.RemoteAddress = $remoteAddress.ToString()
        New-NetOpsResult $check $displayTarget 'Success' "Connected to $($data.RemoteAddress) on port $Port." $data
    }
    catch {
        $cause = $_.Exception.GetBaseException()
        $outcome = 'Error'
        $detail = "$stage failed."
        if ($cause -is [OperationCanceledException] -or
            ($cause -is [Net.Sockets.SocketException] -and $cause.SocketErrorCode -eq 'TimedOut')) {
            $outcome = 'Timed out'
            $detail = "$stage did not complete within the $TimeoutSeconds-second probe budget."
        }
        elseif ($cause -is [Net.Sockets.SocketException]) {
            $data.SocketError = [string]$cause.SocketErrorCode
            switch ($data.SocketError) {
                'ConnectionRefused' {
                    $outcome = 'Refused'
                    $detail = 'The connection attempt was actively refused. For a name with multiple addresses, this reports the final socket error.'
                }
                { $_ -in 'HostUnreachable', 'NetworkUnreachable', 'NetworkDown' } {
                    $outcome = 'Unreachable'
                    $detail = 'The socket reported that the network or destination could not be reached.'
                }
                { $_ -in 'HostNotFound', 'NoData' } {
                    $outcome = 'Name not found'
                    $detail = 'The system resolver could not find an address for this name.'
                }
            }
        }
        $data.Stage = $stage
        $data.ExceptionType = $cause.GetType().Name
        New-NetOpsResult $check $displayTarget $outcome $detail $data
    }
    finally {
        if ($client) { $client.Dispose() }
        $timer.Dispose()
    }
}

function Invoke-NetOpsTrace {
    param([string]$Target, [int]$TimeoutMs, [int]$ResolveTimeoutSeconds)

    $check = 'Traceroute'
    $timer = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($ResolveTimeoutSeconds))
    try {
        $addresses = @(Get-NetOpsTargetAddress $Target $timer.Token)
        if ($addresses.Count -eq 0) {
            return New-NetOpsResult $check $Target 'Name not found' 'The system resolver returned no addresses.'
        }
        $destination = $addresses[0]
    }
    catch {
        $cause = $_.Exception.GetBaseException()
        $outcome = if ($cause -is [OperationCanceledException]) { 'Timed out' } else { 'Error' }
        if ($cause -is [Net.Sockets.SocketException] -and $cause.SocketErrorCode -in 'HostNotFound', 'NoData') {
            $outcome = 'Name not found'
        }
        return New-NetOpsResult $check $Target $outcome 'The system resolver could not supply a destination for the trace.' @{
            ExceptionType = $cause.GetType().Name
        }
    }
    finally { $timer.Dispose() }

    $ping = [Net.NetworkInformation.Ping]::new()
    $summary = 'The destination sent no ICMP echo reply within 20 hops.'
    $finalOutcome = 'No reply'
    $lastHop = 0
    try {
        foreach ($hop in 1..20) {
            $lastHop = $hop
            $samples = @(for ($i = 0; $i -lt 3; $i++) { Get-NetOpsPingSample $ping $destination $TimeoutMs $hop })
            $outcomes = $samples.Outcome
            $outcome = if ($outcomes -contains 'Success') { 'Success' }
                elseif ($outcomes -contains 'Hop reply') { 'Hop reply' }
                elseif ($outcomes -contains 'Unreachable') { 'Unreachable' }
                elseif ($outcomes -contains 'Error' -or $outcomes -contains 'ICMP error') { 'Error' }
                else { 'No reply' }
            $observations = @(foreach ($sample in $samples) {
                if ($sample.Outcome -eq 'Success') { "$($sample.ReplyAddress) ($($sample.RoundTripMs) ms RTT)" }
                elseif ($sample.Outcome -eq 'Hop reply' -and $sample.ReplyAddress -notin '', '0.0.0.0', '::') {
                    "$($sample.ReplyAddress) ($($sample.ElapsedMs) ms elapsed)"
                }
                elseif ($sample.Outcome -eq 'Hop reply') { 'Hop replied without an address' }
                elseif ($sample.Outcome -eq 'No reply') { 'No reply' }
                else { $sample.IcmpStatus }
            })
            New-NetOpsResult "Hop $hop" $destination.ToString() $outcome ($observations -join ' | ') @{
                Hop = $hop; Destination = $destination.ToString(); Samples = $samples
            }
            if ($outcome -eq 'Success') {
                $summary = "The destination returned an ICMP echo reply at hop $hop."
                $finalOutcome = 'Success'
                break
            }
            if (@($outcomes | Where-Object { $_ -ne 'Unreachable' }).Count -eq 0) {
                $summary = "All probes at hop $hop returned an ICMP unreachable indication."
                $finalOutcome = 'Unreachable'
                break
            }
            if (@($outcomes | Where-Object { $_ -notin 'Error', 'ICMP error' }).Count -eq 0) {
                $summary = "Windows could not complete the probes at hop $hop."
                $finalOutcome = 'Error'
                break
            }
        }
    }
    finally { $ping.Dispose() }
    New-NetOpsResult 'Trace summary' $Target $finalOutcome $summary @{
        Destination = $destination.ToString(); HopsTested = $lastHop
    }
}

function Invoke-NetOpsPublicIp {
    param([string[]]$Endpoints, [int]$TimeoutSeconds)

    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
    $client.MaxResponseContentBufferSize = 4096
    try {
        foreach ($endpoint in $Endpoints) {
            $uri = [Uri]$endpoint
            try {
                $text = $client.GetStringAsync($uri).GetAwaiter().GetResult().Trim()
                if ($text.StartsWith('{')) {
                    $body = ConvertFrom-Json -InputObject $text -AsHashtable -ErrorAction Stop
                    $text = $body['ip']
                }
                $ip = $null
                if ($text -isnot [string] -or -not [Net.IPAddress]::TryParse($text, [ref]$ip) -or
                    ($ip.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork -and $ip.ToString() -ne $text) -or
                    $text -match '[\[\]%]' -or [Net.IPAddress]::IsLoopback($ip) -or
                    $ip.Equals([Net.IPAddress]::Any) -or $ip.Equals([Net.IPAddress]::IPv6Any)) {
                    New-NetOpsResult 'Public IP' $uri.Authority 'Unexpected response' 'The service response did not contain a usable IP address.'
                    continue
                }
                return New-NetOpsResult 'Public IP' $uri.Authority 'Success' $ip.ToString() @{
                    ReportedAddress = $ip.ToString(); Endpoint = $endpoint
                }
            }
            catch {
                $cause = $_.Exception.GetBaseException()
                $outcome = if ($cause -is [TimeoutException] -or $cause -is [OperationCanceledException]) { 'Timed out' } else { 'Error' }
                New-NetOpsResult 'Public IP' $uri.Authority $outcome 'The HTTPS service did not return an address.' @{
                    ExceptionType = $cause.GetType().Name
                    HttpStatus = if ($cause -is [Net.Http.HttpRequestException] -and $null -ne $cause.StatusCode) {
                        [int]$cause.StatusCode
                    }
                }
            }
        }
    }
    finally { $client.Dispose() }
}

function Invoke-NetOpsLocalInventory {
    param([string]$ToolId, [string]$Check)

    try {
        $found = 0
        switch ($ToolId) {
            'Adapters' {
                foreach ($item in (Get-NetAdapter -ErrorAction Stop | Sort-Object Name)) {
                    $found++
                    New-NetOpsResult $Check $item.Name 'Observed' "$($item.Status) | $($item.LinkSpeed) | MAC $($item.MacAddress)" @{
                        InterfaceIndex = $item.ifIndex; Status = [string]$item.Status
                        MacAddress = $item.MacAddress; LinkSpeed = $item.LinkSpeed; Description = $item.InterfaceDescription
                    }
                }
            }
            'Addresses' {
                foreach ($item in (Get-NetIPAddress -ErrorAction Stop | Sort-Object InterfaceAlias, AddressFamily, IPAddress)) {
                    $address = [Net.IPAddress]::Parse($item.IPAddress)
                    if ([Net.IPAddress]::IsLoopback($address)) { continue }
                    $found++
                    New-NetOpsResult $Check $item.InterfaceAlias 'Observed' "$($item.IPAddress)/$($item.PrefixLength) | $($item.PrefixOrigin)" @{
                        Address = $item.IPAddress; PrefixLength = $item.PrefixLength; PrefixOrigin = [string]$item.PrefixOrigin
                        Family = [string]$item.AddressFamily; AddressState = [string]$item.AddressState; InterfaceIndex = $item.InterfaceIndex
                    }
                }
            }
            'Neighbors' {
                foreach ($item in (Get-NetNeighbor -AddressFamily IPv4 -ErrorAction Stop | Sort-Object InterfaceIndex, IPAddress)) {
                    $found++
                    New-NetOpsResult $Check $item.IPAddress 'Observed' "$($item.LinkLayerAddress) | $($item.State) | $($item.InterfaceAlias)" @{
                        Address = $item.IPAddress; MacAddress = $item.LinkLayerAddress; State = [string]$item.State
                        Interface = $item.InterfaceAlias; InterfaceIndex = $item.InterfaceIndex
                    }
                }
            }
            'Routes' {
                foreach ($item in (Get-NetRoute -PolicyStore ActiveStore -ErrorAction Stop | Sort-Object AddressFamily, RouteMetric, DestinationPrefix)) {
                    $found++
                    New-NetOpsResult $Check $item.DestinationPrefix 'Observed' "Via $($item.NextHop) | metric $($item.RouteMetric) | $($item.InterfaceAlias)" @{
                        DestinationPrefix = $item.DestinationPrefix; NextHop = $item.NextHop; RouteMetric = $item.RouteMetric
                        Interface = $item.InterfaceAlias; InterfaceIndex = $item.InterfaceIndex; Family = [string]$item.AddressFamily
                    }
                }
            }
            'Connections' {
                $processes = @{}
                Get-Process -ErrorAction SilentlyContinue | ForEach-Object { $processes[[int]$_.Id] = $_.ProcessName }
                $connections = @(Get-NetTCPConnection -ErrorAction Stop | Where-Object State -eq 'Established' |
                    Sort-Object OwningProcess, LocalAddress, LocalPort, RemoteAddress, RemotePort)
                foreach ($item in ($connections | Select-Object -First 60)) {
                    $found++
                    $name = $processes[[int]$item.OwningProcess]
                    if (-not $name) { $name = 'Unknown process' }
                    $remote = [Net.IPEndPoint]::new([Net.IPAddress]::Parse($item.RemoteAddress), $item.RemotePort).ToString()
                    New-NetOpsResult $Check $remote 'Observed' "$name (PID $($item.OwningProcess)) | local port $($item.LocalPort)" @{
                        Process = $name; PID = $item.OwningProcess
                        LocalAddress = $item.LocalAddress; LocalPort = $item.LocalPort
                        RemoteAddress = $item.RemoteAddress; RemotePort = $item.RemotePort
                    }
                }
                if ($connections.Count -gt 60) {
                    New-NetOpsResult $Check '' 'Observed' "Showing 60 of $($connections.Count) established connections." @{
                        Displayed = 60; Total = $connections.Count
                    }
                }
            }
            'DnsServers' {
                foreach ($item in (Get-DnsClientServerAddress -ErrorAction Stop | Where-Object ServerAddresses |
                    Sort-Object InterfaceAlias, AddressFamily)) {
                    $found++
                    New-NetOpsResult $Check $item.InterfaceAlias 'Observed' ($item.ServerAddresses -join ', ') @{
                        Servers = @($item.ServerAddresses); InterfaceIndex = $item.InterfaceIndex
                        Family = if ($item.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6) { 'IPv6' } else { 'IPv4' }
                    }
                }
            }
        }
        if ($found -eq 0) {
            New-NetOpsResult $Check '' 'No data' 'No matching entries were reported by Windows.'
        }
    }
    catch { New-NetOpsProviderError $Check '' $_ }
}

function Invoke-NetOpsWifi {
    $check = 'Wi-Fi interfaces'
    $adapters = @{}
    $reported = $false
    try {
        foreach ($adapter in (Get-NetAdapter -ErrorAction Stop | Where-Object NdisPhysicalMedium -in 1, 9)) {
            $adapters[[Guid]$adapter.InterfaceGuid] = $adapter
        }
    }
    catch {
        $reported = $true
        New-NetOpsProviderError $check '' $_
    }

    try {
        if (-not ('NetOpsToolbox.Windows.Wlan' -as [type])) {
            Add-Type -Path (Join-Path $PSScriptRoot 'NetOps.Wlan.cs') -ErrorAction Stop
        }
        foreach ($snapshot in [NetOpsToolbox.Windows.Wlan]::ReadInterfaces()) {
            $info = $snapshot.Info
            $adapter = $adapters[$info.Id]
            [void]$adapters.Remove($info.Id)
            $name = if ($adapter) { $adapter.Name } else { $info.Description }
            ConvertTo-NetOpsWifiResult -Snapshot $snapshot -Name $name -Adapter $adapter
            $reported = $true
        }
    }
    catch {
        $reported = $true
        $cause = $_.Exception.GetBaseException()
        if ($cause -is [ComponentModel.Win32Exception]) {
            New-NetOpsResult 'WLAN details' '' 'Unavailable' 'Windows could not query the WLAN service.' @{
                WindowsErrorCode = $cause.NativeErrorCode
            }
        }
        else { New-NetOpsProviderError 'WLAN details' '' $_ }
    }

    foreach ($adapter in ($adapters.Values | Sort-Object Name)) {
        $reported = $true
        New-NetOpsResult $check $adapter.Name 'Observed' "Adapter status: $($adapter.Status)." @{
            InterfaceId = $adapter.InterfaceGuid; Status = [string]$adapter.Status
            Description = $adapter.InterfaceDescription; MacAddress = $adapter.MacAddress
        }
    }
    if (-not $reported) {
        New-NetOpsResult $check '' 'No data' 'Windows reported no Wi-Fi interfaces.'
    }
}

function ConvertTo-NetOpsWifiResult {
    param($Snapshot, [string]$Name, $Adapter)

    $radioStates = @{ [uint32]0 = 'Unknown'; [uint32]1 = 'On'; [uint32]2 = 'Off' }
    $info = $Snapshot.Info
    $state = switch ([string]$info.State) {
        'NotReady' { 'Not ready' }
        'AdHocNetworkFormed' { 'Ad hoc network formed' }
        default { [string]$info.State }
    }
    $data = [ordered]@{
        InterfaceId = $info.Id.ToString()
        Description = $info.Description
        State = $state
    }
    if ($Adapter) { $data.MacAddress = $Adapter.MacAddress }
    if ($Snapshot.Radios.Length) {
        $data.Radios = @(foreach ($radio in $Snapshot.Radios) {
            [ordered]@{
                PhyIndex = $radio.PhyIndex
                Hardware = $radioStates[$radio.HardwareState] ?? 'Unknown'
                Software = $radioStates[$radio.SoftwareState] ?? 'Unknown'
            }
        })
    }
    if ($Snapshot.RadioError) { $data.RadioErrorCode = $Snapshot.RadioError }

    $outcome = 'Observed'
    $detail = "WLAN state: $state."
    $connection = $Snapshot.ActiveConnection
    if ($null -ne $connection) {
        $association = $connection.Association
        $ssidLength = $association.SsidLength
        if ($ssidLength -gt 0 -and $ssidLength -le $association.Ssid.Length) {
            $ssidBytes = [byte[]]$association.Ssid[0..($ssidLength - 1)]
            $data.SsidHex = [Convert]::ToHexString($ssidBytes)
            $data.Ssid = [Text.Encoding]::UTF8.GetString($ssidBytes)
        }
        $data.Bssid = [BitConverter]::ToString($association.Bssid)
        $data.Profile = $connection.Profile
        $modes = @{
            0 = 'Profile'; 1 = 'Temporary profile'; 2 = 'Secure discovery'; 3 = 'Open discovery'; 4 = 'Automatic'
        }
        $phyTypes = @{
            [uint32]1 = 'FHSS'; [uint32]2 = 'DSSS'; [uint32]3 = 'Infrared'
            [uint32]4 = 'OFDM'; [uint32]5 = 'HR-DSSS'; [uint32]6 = 'ERP'
            [uint32]7 = '802.11n'; [uint32]8 = '802.11ac'; [uint32]9 = '802.11ad'
            [uint32]10 = '802.11ax'; [uint32]11 = '802.11be'
        }
        $authentication = @{
            [uint32]1 = 'Open'; [uint32]2 = 'Shared key'; [uint32]3 = 'WPA Enterprise'; [uint32]4 = 'WPA Personal'
            [uint32]5 = 'WPA None'; [uint32]6 = 'WPA2 Enterprise'; [uint32]7 = 'WPA2 Personal'
            [uint32]8 = 'WPA3 Enterprise 192-bit'; [uint32]9 = 'WPA3 Personal'
            [uint32]10 = 'Enhanced Open (OWE)'; [uint32]11 = 'WPA3 Enterprise'
        }
        $ciphers = @{
            [uint32]0 = 'None'; [uint32]1 = 'WEP-40'; [uint32]2 = 'TKIP'; [uint32]4 = 'CCMP'
            [uint32]5 = 'WEP-104'; [uint32]6 = 'BIP-CMAC-128'; [uint32]8 = 'GCMP-128'; [uint32]9 = 'GCMP-256'
            [uint32]10 = 'CCMP-256'; [uint32]11 = 'BIP-GMAC-128'; [uint32]12 = 'BIP-GMAC-256'
            [uint32]13 = 'BIP-CMAC-256'; [uint32]256 = 'Group cipher'; [uint32]257 = 'WEP'
        }
        $data.ConnectionMode = $modes[[int]$connection.Mode] ?? "Unknown ($($connection.Mode))"
        $data.NetworkType = @{ 1 = 'Infrastructure'; 2 = 'Ad hoc' }[[int]$association.NetworkType] ?? 'Unknown'
        $data.PhyType = $phyTypes[$association.PhyType] ?? "Unknown ($($association.PhyType))"
        if ($null -ne $Snapshot.Channel) { $data.Channel = $Snapshot.Channel }
        $data.SignalPercent = $association.SignalQuality
        $data.ReceiveRateKbps = $association.ReceiveRateKbps
        $data.TransmitRateKbps = $association.TransmitRateKbps
        $data.SecurityEnabled = [bool]$connection.Security.Enabled
        $data.OneXEnabled = [bool]$connection.Security.OneXEnabled
        $data.Authentication = $authentication[$connection.Security.Authentication] ?? "Unknown ($($connection.Security.Authentication))"
        $data.Encryption = $ciphers[$connection.Security.Cipher] ?? "Unknown ($($connection.Security.Cipher))"
        $detail += " Signal $($association.SignalQuality)%."
    }
    elseif ($Snapshot.ConnectionError) {
        $data.WindowsErrorCode = $Snapshot.ConnectionError
        $outcome = 'Unavailable'
        $detail += switch ($Snapshot.ConnectionError) {
            5 { ' Windows denied access to connection details. Location policy may restrict this query.' }
            5023 { ' The connection state changed before Windows returned its details.' }
            default { " Windows could not read connection details (error $($Snapshot.ConnectionError))." }
        }
    }
    New-NetOpsResult 'Wi-Fi interfaces' $Name $outcome $detail $data
}

function Invoke-NetOpsQuickCheck {
    param([Collections.IDictionary]$Settings)

    $adapterCheck = 'Active physical adapter'
    $addressCheck = 'Usable local IPv4'
    $providerCheck = $adapterCheck
    try {
        $adapters = @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object Status -eq 'Up')
        if ($adapters.Count -gt 0) {
            New-NetOpsResult $adapterCheck ($adapters.Name -join ', ') 'Success' "$($adapters.Count) physical adapter(s) report an active link." @{
                Interfaces = @($adapters | Select-Object Name, ifIndex, LinkSpeed)
            }
        }
        else {
            New-NetOpsResult $adapterCheck '' 'No data' 'No physical adapter reported an active link.'
        }
        $providerCheck = $addressCheck
        if ($adapters.Count -eq 0) {
            New-NetOpsResult $addressCheck '' 'Skipped' 'The IPv4 check uses active physical interfaces.'
        }
        else {
            $addresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
                Where-Object {
                    $_.InterfaceIndex -in $adapters.ifIndex -and $_.IPAddress -notlike '169.254.*' -and
                    $_.IPAddress -ne '0.0.0.0' -and $_.AddressState -in 'Preferred', 'Deprecated'
                } | Select-Object InterfaceAlias, IPAddress, PrefixLength, PrefixOrigin)
            if ($addresses.Count -eq 0) {
                New-NetOpsResult $addressCheck '' 'No data' 'No usable non-link-local IPv4 address was reported on the active physical interfaces.'
            }
            else {
                New-NetOpsResult $addressCheck ($addresses.InterfaceAlias -join ', ') 'Success' ($addresses.IPAddress -join ', ') @{
                    Addresses = $addresses
                }
            }
        }
    }
    catch {
        New-NetOpsProviderError $providerCheck '' $_
        if ($providerCheck -eq $adapterCheck) {
            New-NetOpsResult $addressCheck '' 'Skipped' 'The adapter inventory was unavailable.'
        }
    }

    Invoke-NetOpsGateway 2 $Settings.PingTimeoutMs
    Invoke-NetOpsDnsLookup @($Settings.DnsTargets[0])
    Invoke-NetOpsEcho 'Internet ICMP' ([Net.IPAddress]::Parse($Settings.InternetIcmpAddress)) 2 $Settings.PingTimeoutMs
    Invoke-NetOpsTcp $Settings.InternetTcpHost $Settings.InternetTcpPort $Settings.ConnectTimeoutSeconds
}

function Invoke-NetOpsDiagnostic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Request,
        [Parameter(Mandatory)][Collections.IDictionary]$Settings,
        [Parameter(Mandatory)][string]$Name
    )

    switch ($Request.ToolId) {
        'QuickCheck' { Invoke-NetOpsQuickCheck $Settings }
        'Gateway' { Invoke-NetOpsGateway 4 $Settings.PingTimeoutMs }
        'Dns' {
            $names = if ($Request.Target) { @($Request.Target) } else { $Settings.DnsTargets }
            Invoke-NetOpsDnsLookup $names
        }
        'Internet' {
            Invoke-NetOpsEcho 'Internet ICMP' ([Net.IPAddress]::Parse($Settings.InternetIcmpAddress)) 4 $Settings.PingTimeoutMs
            Invoke-NetOpsTcp $Settings.InternetTcpHost $Settings.InternetTcpPort $Settings.ConnectTimeoutSeconds
        }
        'Tcp' { Invoke-NetOpsTcp $Request.Target $Request.Port $Settings.ConnectTimeoutSeconds }
        'Trace' { Invoke-NetOpsTrace $Request.Target $Settings.TraceTimeoutMs $Settings.ConnectTimeoutSeconds }
        'PublicIp' { Invoke-NetOpsPublicIp $Settings.PublicIpEndpoints $Settings.PublicIpTimeoutSeconds }
        'Wifi' { Invoke-NetOpsWifi }
        default { Invoke-NetOpsLocalInventory $Request.ToolId $Name }
    }
}

Export-ModuleMember -Function Invoke-NetOpsDiagnostic
