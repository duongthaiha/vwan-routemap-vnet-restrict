[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ResourceGroup,

    [Parameter(Mandatory)]
    [string] $SubscriptionId,

    [Parameter(Mandatory)]
    [string] $EvidenceFile,

    [switch] $SkipConnectivity
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-AzJson {
    param([Parameter(Mandatory)][string[]] $Arguments)

    $result = & az @Arguments --subscription $SubscriptionId --only-show-errors --output json
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI failed: az $($Arguments[0..1] -join ' ') (exit $LASTEXITCODE)."
    }
    if (-not $result) {
        throw "Azure CLI returned no JSON for: az $($Arguments[0..1] -join ' ')."
    }
    return ($result | ConvertFrom-Json)
}

$evidence = [ordered]@{
    collectedAtUtc     = [DateTime]::UtcNow.ToString('o')
    subscriptionId    = $SubscriptionId
    resourceGroup     = $ResourceGroup
    complete          = $false
    vpnSites          = [ordered]@{}
    localGateways     = [ordered]@{}
    vpnConnections    = [ordered]@{}
    hubConnections    = [ordered]@{}
    hubRoutes          = [ordered]@{}
    nicRoutes          = [ordered]@{}
    effectiveNsgs      = [ordered]@{}
    privateIps         = [ordered]@{}
    routeMap           = $null
    probes             = @()
    acceptance         = @()
}

$fullEvidencePath = [System.IO.Path]::GetFullPath($EvidenceFile)
$evidenceDirectory = Split-Path -Parent $fullEvidencePath
New-Item -ItemType Directory -Force -Path $evidenceDirectory | Out-Null
$probeFile = $null

try {
    foreach ($endpoint in @('primary', 'secondary')) {
        $evidence.vpnSites[$endpoint] = Invoke-AzJson -Arguments @(
            'network', 'vpn-site', 'show', '-g', $ResourceGroup, '-n', "site-oci-$endpoint",
            '--query', '{name:name,addressSpace:addressSpace,vpnSiteLinks:vpnSiteLinks[].{name:name,ipAddress:ipAddress}}'
        )
        $evidence.localGateways[$endpoint] = Invoke-AzJson -Arguments @(
            'network', 'local-gateway', 'show', '-g', $ResourceGroup, '-n', "lng-hub-a-$endpoint",
            '--query', '{name:name,addressSpace:localNetworkAddressSpace,gatewayIpAddress:gatewayIpAddress}'
        )
        $evidence.vpnConnections["simulator-$endpoint"] = Invoke-AzJson -Arguments @(
            'network', 'vpn-connection', 'show', '-g', $ResourceGroup, '-n', "connection-hub-a-$endpoint",
            '--query', '{name:name,status:connectionStatus,provisioningState:provisioningState,bgp:enableBgp,ipsecPolicies:ipsecPolicies}'
        )
        $evidence.vpnConnections["hub-$endpoint"] = Invoke-AzJson -Arguments @(
            'network', 'vpn-gateway', 'connection', 'show', '-g', $ResourceGroup,
            '--gateway-name', 'vpng-hub-a', '-n', "connection-oci-$endpoint",
            '--query', '{name:name,provisioningState:provisioningState,links:vpnLinkConnections[].{name:name,status:vpnConnectionStatus,provisioningState:provisioningState,bgp:enableBgp,protocol:vpnConnectionProtocolType,ipsecPolicies:ipsecPolicies}}'
        )
    }

    $evidence.routeMap = Invoke-AzJson -Arguments @(
        'network', 'vhub', 'route-map', 'show', '-g', $ResourceGroup, '--vhub-name', 'hub-b', '-n', 'RM-DROP-OCI'
    )
    foreach ($name in @('a', 'b')) {
        $connection = Invoke-AzJson -Arguments @(
            'network', 'vhub', 'connection', 'show', '-g', $ResourceGroup,
            '--vhub-name', "hub-$name", '-n', "connection-vnet-$name"
        )
        $evidence.hubConnections[$name] = $connection
        $hub = Invoke-AzJson -Arguments @(
            'network', 'vhub', 'show', '-g', $ResourceGroup, '-n', "hub-$name", '--query', '{id:id}'
        )
        $evidence.hubRoutes[$name] = [ordered]@{
            defaultTable = Invoke-AzJson -Arguments @(
                'network', 'vhub', 'get-effective-routes', '-g', $ResourceGroup, '-n', "hub-$name",
                '--resource-type', 'RouteTable', '--resource-id', "$($hub.id)/hubRouteTables/defaultRouteTable"
            )
            vnetConnection = Invoke-AzJson -Arguments @(
                'network', 'vhub', 'get-effective-routes', '-g', $ResourceGroup, '-n', "hub-$name",
                '--resource-type', 'HubVirtualNetworkConnection', '--resource-id', $connection.id
            )
        }
    }

    foreach ($name in @('a', 'b', 'oci')) {
        $evidence.nicRoutes[$name] = @(Invoke-AzJson -Arguments @(
            'network', 'nic', 'show-effective-route-table', '-g', $ResourceGroup, '-n', "nic-$name"
        ))
        $evidence.effectiveNsgs[$name] = @(Invoke-AzJson -Arguments @(
            'network', 'nic', 'list-effective-nsg', '-g', $ResourceGroup, '-n', "nic-$name"
        ))
        $nic = Invoke-AzJson -Arguments @(
            'network', 'nic', 'show', '-g', $ResourceGroup, '-n', "nic-$name",
            '--query', '{privateIp:ipConfigurations[0].privateIPAddress || ipConfigurations[0].privateIpAddress}'
        )
        if (-not $nic.privateIp) {
            throw "Could not determine the private IP of nic-$name."
        }
        $evidence.privateIps[$name] = $nic.privateIp
    }

    if (-not $SkipConnectivity) {
        $probeSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'connectivity_probe.py') -Raw
        $guestScript = @'
#!/bin/sh
exec python3 - "$@" <<'POC_PROBE'
'@ + "`n" + $probeSource + "`nPOC_PROBE`n"
        $probeFile = [System.IO.Path]::GetTempFileName()
        [System.IO.File]::WriteAllText($probeFile, $guestScript, [System.Text.UTF8Encoding]::new($false))

        $targets = @{
            a   = @('local', '127.0.0.1', 'oci', $evidence.privateIps.oci)
            b   = @('local', '127.0.0.1', 'oci', $evidence.privateIps.oci)
            oci = @('local', '127.0.0.1', 'a', $evidence.privateIps.a, 'b', $evidence.privateIps.b)
        }
        $probes = [System.Collections.Generic.List[object]]::new()
        foreach ($source in @('a', 'b', 'oci')) {
            Write-Host "Probing from vm-$source..."
            $runCommand = @(
                'vm', 'run-command', 'invoke', '-g', $ResourceGroup, '-n', "vm-$source",
                '--command-id', 'RunShellScript', '--scripts', "@$probeFile", '--parameters'
            ) + $targets[$source]
            $response = Invoke-AzJson -Arguments $runCommand
            $messages = @($response.value | ForEach-Object { $_.message }) -join "`n"
            $matches = [regex]::Matches($messages, '(?m)^POC_RESULT=(\{[^\r\n]*\})\s*$')
            if ($matches.Count -ne $targets[$source].Count) {
                throw "vm-$source returned $($matches.Count) probe results; expected $($targets[$source].Count)."
            }
            foreach ($match in $matches) {
                $probe = $match.Groups[1].Value | ConvertFrom-Json
                $probes.Add([pscustomobject]@{
                    source    = $source
                    target    = $probe.target
                    host      = $probe.host
                    port      = $probe.port
                    connected = $probe.connected
                    error     = if ($probe.PSObject.Properties['error']) { $probe.error } else { $null }
                })
            }
            $evidence.probes = @($probes.ToArray())
        }

        $expectations = @(
            @{ source = 'a'; target = 'oci'; connected = $true },
            @{ source = 'oci'; target = 'a'; connected = $true },
            @{ source = 'b'; target = 'oci'; connected = $false },
            @{ source = 'oci'; target = 'b'; connected = $false }
        )
        $failures = [System.Collections.Generic.List[string]]::new()
        foreach ($source in @('a', 'b', 'oci')) {
            foreach ($port in @(22, 30289)) {
                $local = @($probes | Where-Object { $_.source -eq $source -and $_.target -eq 'local' -and $_.port -eq $port })
                if ($local.Count -ne 1 -or -not $local[0].connected) {
                    $failures.Add("vm-$source has no confirmed local listener on TCP $port")
                }
            }
        }
        foreach ($expectation in $expectations) {
            foreach ($port in @(22, 30289)) {
                $result = @($probes | Where-Object {
                    $_.source -eq $expectation.source -and $_.target -eq $expectation.target -and $_.port -eq $port
                })
                if ($result.Count -ne 1) {
                    $failures.Add("Missing or duplicate $($expectation.source) to $($expectation.target) TCP $port result")
                    continue
                }
                $passed = $result[0].connected -eq $expectation.connected
                $evidence.acceptance += [pscustomobject]@{
                    source   = $expectation.source
                    target   = $expectation.target
                    port     = $port
                    expected = if ($expectation.connected) { 'connected' } else { 'not connected' }
                    actual   = if ($result[0].connected) { 'connected' } else { 'not connected' }
                    passed   = $passed
                    detail   = $result[0].error
                }
                if (-not $passed) {
                    $failures.Add("$($expectation.source) to $($expectation.target) TCP $port did not match expectation")
                }
            }
        }
        $evidence.acceptance | Format-Table | Out-Host
        if ($failures.Count -gt 0) {
            throw ($failures -join '; ')
        }
    }

    $evidence.complete = $true
}
finally {
    if ($probeFile -and (Test-Path -LiteralPath $probeFile)) {
        Remove-Item -LiteralPath $probeFile
    }
    $evidence | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $fullEvidencePath -Encoding utf8
    Write-Host "Evidence saved to $fullEvidencePath"
}
