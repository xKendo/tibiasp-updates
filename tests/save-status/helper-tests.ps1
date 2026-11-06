$ErrorActionPreference = 'Stop'
$env:LOCALAPPDATA = Join-Path ([IO.Path]::GetTempPath()) ('tibiasp-helper-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force | Out-Null
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $repoRoot 'packages/v0.5.7/source/payload/TIBIA_REAL860.ps1')

$originals = @{}
foreach ($name in @('Invoke-Docker','Find-Docker','Docker-IsReady','Start-Sleep','Save-ExistingWorld','Get-ServiceContainer','Get-ContainerById')) {
    $command = Get-Command $name
    if ($command.CommandType -eq 'Function') { $originals[$name] = $command.ScriptBlock }
}
$script:passed = 0
$script:testNumber = 0

function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw ('ASSERT: ' + $Message) } }
function Assert-Throws([scriptblock]$Body, [string]$Pattern) {
    $caught = $false
    try { & $Body } catch { $caught = $true; Assert ($_.Exception.Message -match $Pattern) ('Unexpected failure: ' + $_.Exception.Message) }
    Assert $caught ('Expected failure matching ' + $Pattern)
}
function New-TestState {
    foreach ($name in $originals.Keys) { Set-Item ('Function:\' + $name) $originals[$name] }
    Remove-Item Function:\Start-Sleep -ErrorAction SilentlyContinue
    $script:testNumber++
    $root = Join-Path $env:LOCALAPPDATA ('case-' + $script:testNumber)
    $script:base = $root
    $script:project = Join-Path $root 'silnik-8.60'
    $script:compose = Join-Path $script:project 'server/compose.yaml'
    $script:data = Join-Path $script:project 'server/data'
    $script:controlDir = Join-Path $root 'control'
    $script:policyFile = Join-Path $script:controlDir 'policy.json'
    New-Item -ItemType Directory -Path $script:data -Force | Out-Null
    New-Item -ItemType Directory -Path $script:controlDir -Force | Out-Null
    [IO.File]::WriteAllText($script:compose, "services:`n  server:`n    restart: unless-stopped`n")
    $script:game = [pscustomobject]@{ id=('a'*64); state='running'; running=$true; restarting=$false; health=$null; exitCode=0; oomKilled=$false; restartName='unless-stopped'; restartRetries=0 }
    $script:database = [pscustomobject]@{ id=('b'*64); state='running'; running=$true; restarting=$false; health='healthy'; exitCode=0; oomKilled=$false; restartName='unless-stopped'; restartRetries=0 }
    $script:operationResult = [pscustomobject]@{schema=1;operationId=('a'*32);action='save';success=$false;saveConfirmed=$false;stopConfirmed=$false;message=''}
    $script:dockerCalls = New-Object 'System.Collections.Generic.List[object]'
    $script:events = New-Object 'System.Collections.Generic.List[string]'
    $script:scenario = 'success'
    $script:processingTicks = 0
    $script:commands = New-Object 'System.Collections.Generic.List[string]'
    $script:missingDatabase = $false
    $script:duplicateServer = $false
    $script:shutdownExitCode = 0
    $script:shutdownOom = $false
    $script:observedOverride = ''
    Set-Item Function:\Find-Docker { return 'mock-docker-never-executed' }
    Set-Item Function:\Start-Sleep { param($Seconds,$Milliseconds) }
    Set-Item Function:\Invoke-Docker {
        param([string[]]$Arguments)
        $script:dockerCalls.Add(@($Arguments))
        switch ($Arguments[0]) {
            'info' { return 'mock-daemon' }
            'ps' {
                $filter = $Arguments -join ' '
                Assert ($filter -match 'label=com.docker.compose.project=tibiasp-real860') 'Project label must be explicit'
                if ($filter -match 'service=database') {
                    if (-not $script:missingDatabase) { return $script:database.id }
                    return
                }
                if ($filter -match 'service=server') {
                    if ($script:duplicateServer) { return @($script:game.id, 'unexpected-one-off') }
                    return $script:game.id
                }
                throw 'Unrecognized service filter'
            }
            'inspect' {
                Assert ($Arguments[2] -eq '{{json .State}}{{println}}{{json .HostConfig.RestartPolicy}}{{println}}{{.Id}}') 'Native-safe inspect template'
                if ($Arguments[-1] -eq $script:game.id) {
                    $request = Join-Path $script:data 'tibiasp_launcher.request'
                    $processing = Join-Path $script:data 'tibiasp_launcher.processing'
                    $response = Join-Path $script:data 'tibiasp_launcher.response'
                    if (Test-Path -LiteralPath $request) {
                        $parts = [IO.File]::ReadAllText($request).Trim().Split(' ')
                        Assert ($parts.Count -eq 2 -and $parts[1] -match '^[a-f0-9]{32}$') 'Wire command carries a 32-hex ID'
                        $script:commands.Add($parts[0])
                        [IO.File]::Move($request, $processing)
                        $ack = @{PING='READY'; SAVE='SAVE_DONE'; SHUTDOWN='SHUTDOWN_ACCEPTED'}[$parts[0]]
                        if ($script:scenario -eq 'shutdown-error' -and $parts[0] -eq 'SHUTDOWN') { $ack='ERROR shutdown_failed' }
                        if ($script:scenario -eq 'engine-error') { $ack='ERROR save_failed' }
                        $temp = $response + '.tmp'
                        [IO.File]::WriteAllText($temp, ($parts[1] + ' ' + $ack + "`n"))
                        if (Test-Path -LiteralPath $response) { Remove-Item -LiteralPath $response }
                        [IO.File]::Move($temp, $response)
                        $script:events.Add('ack:' + $parts[0])
                        if ($ack -notlike 'ERROR*') {
                            if ($script:scenario -eq 'processing-delay') { $script:processingTicks=2 }
                            else { Remove-Item -LiteralPath $processing }
                            if ($parts[0] -eq 'SHUTDOWN') {
                                $script:game.state='exited';$script:game.running=$false
                                $script:game.exitCode=$script:shutdownExitCode;$script:game.oomKilled=$script:shutdownOom
                            }
                        }
                    } elseif ($script:processingTicks -gt 0) {
                        $script:processingTicks--
                        if ($script:processingTicks -eq 0) { Remove-Item -LiteralPath $processing }
                    }
                    $c=$script:game
                } elseif ($Arguments[-1] -eq $script:database.id) { $c=$script:database }
                else { throw ('Unexpected inspected ID: ' + $Arguments[-1]) }
                [pscustomobject]@{Status=$c.state;Running=$c.running;Restarting=$c.restarting;ExitCode=$c.exitCode;OOMKilled=$c.oomKilled;Health=$(if($c.health){[pscustomobject]@{Status=$c.health}}else{$null})} | ConvertTo-Json -Compress
                [pscustomobject]@{Name=$c.restartName;MaximumRetryCount=$c.restartRetries} | ConvertTo-Json -Compress
                return $c.id
            }
            'start' {
                Assert ($Arguments.Count -eq 2 -and $Arguments[1] -eq $script:database.id) 'Only the existing DB container may be started directly'
                $script:database.state='running';$script:database.running=$true;$script:database.health='healthy'
                $script:events.Add('start:database')
                return $script:database.id
            }
            'update' {
                Assert ($Arguments[-1] -eq $script:game.id) 'Restart updates target exact game ID'
                $policy = $Arguments[1].Substring('--restart='.Length).Split(':')
                $script:game.restartName=$policy[0]
                $script:game.restartRetries=$(if($policy.Count -gt 1){[int]$policy[1]}else{0})
                $script:events.Add('policy:' + $policy[0])
                return $script:game.id
            }
            'compose' {
                $joined=$Arguments -join ' '
                Assert ($joined -match 'up --no-deps --no-build --pull never --detach server$') ('Only stopped game may be reconciled: ' + $joined)
                $fIndices = @(for($i=0;$i -lt $Arguments.Count;$i++){if($Arguments[$i] -eq '-f'){$i}})
                Assert ($fIndices.Count -eq 2) 'Temporary override must be supplied'
                $script:observedOverride = [IO.File]::ReadAllText($Arguments[$fIndices[1]+1])
                Assert ($script:observedOverride -match 'restart: "no"') 'Startup override must disable restart'
                Assert ($script:database.state -eq 'running' -and $script:database.health -eq 'healthy') 'DB must be healthy before game startup'
                $script:game.id=('c'*64);$script:game.state='running';$script:game.running=$true;$script:game.restartName='no';$script:game.restartRetries=0
                $script:events.Add('compose:server')
                return
            }
            default { throw ('Unexpected Docker command: ' + ($Arguments -join ' ')) }
        }
    }
}
function Test([string]$Name,[scriptblock]$Body) {
    New-TestState
    & $Body
    $script:passed++
    Write-Host ('PASS ' + $Name)
}

Test 'Save requires healthy DB and PING before SAVE' {
    Save-ExistingWorld
    Assert $script:operationResult.saveConfirmed 'Save flag'
    Assert (($script:commands -join ',') -eq 'PING,SAVE') 'Correct command order'
    Assert (-not @($script:dockerCalls | Where-Object {$_[0] -in @('update','start','compose')}).Count) 'Save changes no container lifecycle'
}
Test 'Unhealthy database blocks SAVE before writing command' {
    $script:database.state='exited';$script:database.running=$false;$script:database.health=$null
    Assert-Throws {Save-ExistingWorld} 'Database is not ready'
    Assert (-not $script:commands.Count) 'No commands consumed'
    Assert (-not (Test-Path (Join-Path $script:data 'tibiasp_launcher.request'))) 'No request published'
}
Test 'Restarting game blocks SAVE' {
    $script:game.state='restarting';$script:game.restarting=$true
    Assert-Throws {Save-ExistingWorld} 'not ready'
    Assert (-not $script:commands.Count) 'No commands consumed'
}
Test 'Pending request is retained byte for byte' {
    $request=Join-Path $script:data 'tibiasp_launcher.request'
    [IO.File]::WriteAllText($request,'SHUTDOWN old-evidence')
    Assert-Throws {Send-LauncherCommand 'PING' 'READY' $script:game.id} 'Pending command evidence'
    Assert ([IO.File]::ReadAllText($request) -eq 'SHUTDOWN old-evidence') 'Evidence unchanged'
}
Test 'Stale ACK ignored; matching ACK waits for processing release' {
    [IO.File]::WriteAllText((Join-Path $script:data 'tibiasp_launcher.response'), (('0'*32) + ' SAVE_DONE'))
    $script:scenario='processing-delay'
    Send-LauncherCommand 'PING' 'READY' $script:game.id
    Assert ($script:processingTicks -eq 0) 'Waited for processing to finish'
    Assert (-not (Test-Path (Join-Path $script:data 'tibiasp_launcher.processing'))) 'No pending processing after success'
}
Test 'Engine ERROR is failure and processing evidence remains' {
    $script:scenario='engine-error'
    Assert-Throws {Send-LauncherCommand 'SAVE' 'SAVE_DONE' $script:game.id} 'Engine rejected SAVE: save_failed'
    Assert (Test-Path (Join-Path $script:data 'tibiasp_launcher.processing')) 'Failure evidence retained'
}
Test 'Channel timeout retains request and never kills game' {
    Assert-Throws {Send-LauncherCommand 'SAVE' 'SAVE_DONE' $script:game.id 0} 'No complete matching SAVE_DONE'
    Assert (Test-Path (Join-Path $script:data 'tibiasp_launcher.request')) 'Timed out request retained'
    Assert (-not @($script:dockerCalls | Where-Object {$_[0] -in @('stop','kill','update','compose')}).Count) 'No force stop'
}
Test 'Safe stop confirms save and exit; leaves DB up and restart disabled' {
    Stop-ExistingWorld
    Assert ($script:operationResult.saveConfirmed -and $script:operationResult.stopConfirmed) 'Both confirmations'
    Assert (($script:commands -join ',') -eq 'PING,SAVE,SHUTDOWN') 'Correct wire order'
    Assert ($script:game.restartName -eq 'no' -and $script:game.state -eq 'exited') 'Game safely stopped'
    Assert ($script:database.state -eq 'running') 'Database left running'
    Assert ((Read-RestartPolicy).name -eq 'unless-stopped') 'Original policy retained'
    Assert (-not @($script:dockerCalls | Where-Object {$_[0] -in @('stop','kill','compose')}).Count) 'No full-stack stop or forced kill'
}
Test 'Failed shutdown does not restore automatic restart' {
    $script:scenario='shutdown-error'
    Assert-Throws {Stop-ExistingWorld} 'Engine rejected SHUTDOWN'
    Assert ($script:game.restartName -eq 'no') 'Restart stays disabled after error'
    Assert ((Read-RestartPolicy).name -eq 'unless-stopped') 'Original policy survives failure'
    Assert (-not $script:operationResult.stopConfirmed) 'Stop not falsely confirmed'
    Assert (($script:events | Where-Object {$_ -like 'policy:*'}) -join ',' -eq 'policy:no') 'No finally restoration'
}
Test 'Abnormal shutdown exit is not safe-stop success' {
    $script:shutdownExitCode=137
    Assert-Throws {Stop-ExistingWorld} 'exited abnormally'
    Assert ($script:operationResult.saveConfirmed -and -not $script:operationResult.stopConfirmed) 'Only save is confirmed'
    Assert ($script:game.restartName -eq 'no') 'No auto restart after crash'
}
Test 'OOM shutdown is not safe-stop success even with exit zero' {
    $script:shutdownOom=$true
    Assert-Throws {Stop-ExistingWorld} 'exited abnormally'
    Assert (-not $script:operationResult.stopConfirmed) 'OOM not success'
}
Test 'Explicit start uses existing DB and only stopped game; restores after readiness' {
    $script:game.state='exited';$script:game.running=$false
    $script:database.state='exited';$script:database.running=$false;$script:database.health=$null
    Start-ExistingInstallation
    Assert ($script:game.id -eq ('c'*64) -and $script:game.state -eq 'running') 'Updater-built game may be recreated'
    Assert ($script:game.restartName -eq 'unless-stopped') 'Original policy restored'
    Assert (-not (Test-Path $script:policyFile)) 'Restored policy evidence retired'
    $events=@($script:events)
    Assert ([array]::IndexOf($events,'start:database') -lt [array]::IndexOf($events,'compose:server')) 'DB before game'
    Assert ([array]::IndexOf($events,'ack:PING') -lt [array]::IndexOf($events,'policy:unless-stopped')) 'READY before policy restore'
    Assert (-not @(Get-ChildItem $script:controlDir -Filter '*.yaml').Count) 'Temporary override cleaned'
}
Test 'Explicit start preserves original restart=no' {
    $script:game.state='exited';$script:game.running=$false;$script:game.restartName='no'
    Start-ExistingInstallation
    Assert ($script:game.restartName -eq 'no') 'Manual no policy preserved'
}
Test 'Already-running game is checked but never restarted' {
    Start-ExistingInstallation
    Assert (($script:commands -join ',') -eq 'PING') 'Readiness PING only'
    Assert (-not @($script:dockerCalls | Where-Object {$_[0] -in @('start','compose')}).Count) 'No lifecycle change'
}
Test 'Restarting game refuses START before starting stopped DB' {
    $script:game.state='restarting';$script:game.restarting=$true
    $script:database.state='exited';$script:database.running=$false
    Assert-Throws {Start-ExistingInstallation} 'not restarted or recreated'
    Assert (-not @($script:dockerCalls | Where-Object {$_[0] -in @('start','compose')}).Count) 'No lifecycle change'
}
Test 'Missing existing DB cannot trigger creation or seed SQL' {
    $script:game.state='exited';$script:game.running=$false;$script:missingDatabase=$true
    Assert-Throws {Start-ExistingInstallation} 'existing database container'
    Assert (-not @($script:dockerCalls | Where-Object {$_[0] -in @('start','compose')}).Count) 'No create/start of unknown DB'
}
Test 'Ambiguous service IDs are rejected' {
    $script:duplicateServer=$true
    Assert-Throws {Get-ServiceContainer 'server'} 'found 2'
}
Test 'Missing Docker state fields cannot become a clean exit' {
    Set-Item Function:\Invoke-Docker {param([string[]]$Arguments) return $script:parserRaw}
    foreach ($missing in @('Status','Running','Restarting','ExitCode','OOMKilled')) {
        $state=@{Status='exited';Running=$false;Restarting=$false;ExitCode=0;OOMKilled=$false}
        $state.Remove($missing)
        $script:parserRaw=@(($state|ConvertTo-Json -Compress),'{"Name":"no","MaximumRetryCount":0}',('a'*64))
        Assert-Throws {Get-ContainerById ('a'*64)} 'invalid container state'
    }
}
Test 'Incorrect Docker state value types are rejected without coercion' {
    Set-Item Function:\Invoke-Docker {param([string[]]$Arguments) return $script:parserRaw}
    foreach ($case in @(
        @{field='Running';value='false'}, @{field='Restarting';value=0},
        @{field='OOMKilled';value=$null}, @{field='ExitCode';value='0'},
        @{field='ExitCode';value=[double]0}, @{field='ExitCode';value=$false},
        @{field='Status';value=0}
    )) {
        $state=@{Status='exited';Running=$false;Restarting=$false;ExitCode=0;OOMKilled=$false}
        $state[$case.field]=$case.value
        $script:parserRaw=@(($state|ConvertTo-Json -Compress),'{"Name":"no","MaximumRetryCount":0}',('a'*64))
        Assert-Throws {Get-ContainerById ('a'*64)} 'invalid container state'
    }
}
Test 'Malformed policy health and full container ID fail closed' {
    Set-Item Function:\Invoke-Docker {param([string[]]$Arguments) return $script:parserRaw}
    $validState='{"Status":"exited","Running":false,"Restarting":false,"ExitCode":0,"OOMKilled":false}'
    foreach ($policy in @(
        '{"MaximumRetryCount":0}', '{"Name":"no"}',
        '{"Name":0,"MaximumRetryCount":0}', '{"Name":"invalid","MaximumRetryCount":0}',
        '{"Name":"no","MaximumRetryCount":"0"}', '{"Name":"no","MaximumRetryCount":-1}',
        '{"Name":"no","MaximumRetryCount":0.5}'
    )) {
        $script:parserRaw=@($validState,$policy,('a'*64))
        Assert-Throws {Get-ContainerById ('a'*64)} 'invalid restart policy'
    }
    $script:parserRaw=@('{"Status":"running","Running":true,"Restarting":false,"ExitCode":0,"OOMKilled":false,"Health":{}}','{"Name":"no","MaximumRetryCount":0}',('a'*64))
    Assert-Throws {Get-ContainerById ('a'*64)} 'invalid healthcheck state'
    foreach ($id in @('short-id','',('a'*63),('g'*64))) {
        $script:parserRaw=@($validState,'{"Name":"no","MaximumRetryCount":0}',$id)
        Assert-Throws {Get-ContainerById 'short-id'} 'incomplete|invalid'
    }
}
Test 'Native nonzero exit code is an error' {
    Set-Item Function:\Invoke-Docker $originals['Invoke-Docker']
    $script:dockerExe='/bin/sh'
    Assert-Throws {$null=Invoke-Docker @('-c','echo simulated-native-failure >&2; exit 23')} 'exit 23'
}
Test 'Final failure JSON is complete and carries operation identity' {
    $script:ResultFile=Join-Path $script:controlDir 'failure-result.json'
    $script:OperationId='0123456789abcdef0123456789abcdef';$script:Action='save'
    Set-Item Function:\Save-ExistingWorld {throw 'simulated controlled failure'}
    $code=Invoke-Main
    Assert ($code -eq 1) 'Failure exit code'
    $result=[IO.File]::ReadAllText($script:ResultFile)|ConvertFrom-Json
    Assert ($result.schema -eq 1 -and $result.operationId -eq $script:OperationId -and $result.action -eq 'save') 'Result identity'
    Assert (-not $result.success -and -not $result.saveConfirmed -and $result.message -eq 'simulated controlled failure') 'Failure result'
    Assert (-not @(Get-ChildItem $script:controlDir -Filter '.result-*.tmp').Count) 'No partial result left'
}
Test 'Final success JSON reports verified save flags' {
    $script:ResultFile=Join-Path $script:controlDir 'success-result.json'
    $script:OperationId='abcdef0123456789abcdef0123456789';$script:Action='save'
    $code=Invoke-Main
    Assert ($code -eq 0) 'Success exit code'
    $result=[IO.File]::ReadAllText($script:ResultFile)|ConvertFrom-Json
    Assert ($result.success -and $result.saveConfirmed -and -not $result.stopConfirmed) 'Verified flags'
}
Write-Host ('Helper tests passed: ' + $script:passed)
