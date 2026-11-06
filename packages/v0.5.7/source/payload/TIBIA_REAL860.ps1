param(
    [ValidateSet('start', 'stop', 'save', 'safestop', 'status', 'logs', 'diagnose')]
    [string]$Action = 'start',
    [ValidatePattern('^[0-9a-fA-F]{32}$')]
    [string]$OperationId,
    [string]$ResultFile
)

$ErrorActionPreference = 'Stop'
$script:base = $PSScriptRoot
$script:project = Join-Path $script:base 'silnik-8.60'
$script:compose = Join-Path $script:project 'server\compose.yaml'
$script:data = Join-Path $script:project 'server\data'
$script:projectName = 'tibiasp-real860'
$script:controlDir = Join-Path $env:LOCALAPPDATA 'TibiaSP\Launcher'
$script:policyFile = Join-Path $script:controlDir 'restart-tibiasp-real860-server.json'
$script:dockerExe = $null
$script:containerFormat = '{{json .State}}{{println}}{{json .HostConfig.RestartPolicy}}{{println}}{{.Id}}'

function Note([string]$Message) { Write-Host ('[TIBIA SP] ' + $Message) }

function Invoke-Docker([string[]]$Arguments) {
    $previousPreference = $ErrorActionPreference
    try {
        # Windows PowerShell wraps native stderr as ErrorRecord. Check the native
        # exit code explicitly instead of letting that stream abort the action.
        $ErrorActionPreference = 'Continue'
        $output = @(& $script:dockerExe @Arguments 2>&1)
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousPreference }
    if ($code -ne 0) {
        throw ('Docker command failed (exit ' + $code + '): ' + ($output -join ' '))
    }
    foreach ($line in $output) { [string]$line }
}

function Find-Docker {
    $command = Get-Command docker.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    $candidates = @(
        $(if ($command) { $command.Source }),
        'C:\Program Files\Docker\Docker\resources\bin\docker.exe',
        (Join-Path $env:LOCALAPPDATA 'Programs\DockerDesktop\resources\bin\docker.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\DockerDesktop\resources\docker.exe')
    )
    $found = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
    if (-not $found) { throw 'docker.exe was not found. Check the Docker Desktop installation.' }
    return $found
}

function Docker-IsReady {
    try { $null = Invoke-Docker @('info', '--format', '{{.ServerVersion}}'); return $true }
    catch { return $false }
}

function Require-Docker {
    $script:dockerExe = Find-Docker
    if (-not (Docker-IsReady)) { throw 'Docker is unavailable. No command was sent to the game.' }
}

function Wait-Docker {
    $script:dockerExe = Find-Docker
    if (Docker-IsReady) { return }
    $candidates = @(
        'C:\Program Files\Docker\Docker\Docker Desktop.exe',
        (Join-Path $env:LOCALAPPDATA 'Programs\DockerDesktop\Docker Desktop.exe')
    )
    $desktop = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if (-not $desktop) { throw 'Docker is unavailable and Docker Desktop.exe was not found.' }
    if (-not (Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue)) {
        Start-Process -FilePath $desktop | Out-Null
    }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($clock.Elapsed.TotalSeconds -lt 240) {
        if (Docker-IsReady) { return }
        Start-Sleep -Seconds 2
    }
    throw 'Docker Desktop did not become ready. No game container was started.'
}

function Compose([string[]]$Arguments, [string]$OverrideFile) {
    if (-not (Test-Path -LiteralPath $script:compose -PathType Leaf)) { throw 'Missing server\compose.yaml.' }
    $command = @('compose', '-p', $script:projectName, '-f', $script:compose)
    if ($OverrideFile) { $command += @('-f', $OverrideFile) }
    Invoke-Docker ($command + $Arguments)
}

function Test-JsonInteger($Value) {
    return ($Value -is [sbyte] -or $Value -is [byte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64])
}

function Get-ContainerById([string]$ContainerId) {
    $raw = @(Invoke-Docker @('inspect', '--format', $script:containerFormat, $ContainerId))
    $raw = @($raw | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($raw.Count -ne 3) { throw 'Docker returned an incomplete container inspection.' }
    $state = $raw[0] | ConvertFrom-Json
    $policy = $raw[1] | ConvertFrom-Json
    $fullId = $raw[2].Trim()
    if ($fullId -notmatch '^[0-9a-f]{64}$' -or
        $state.Status -isnot [string] -or $state.Status -notin @('created', 'running', 'paused', 'restarting', 'removing', 'exited', 'dead') -or
        $state.Running -isnot [bool] -or $state.Restarting -isnot [bool] -or $state.OOMKilled -isnot [bool] -or
        -not (Test-JsonInteger $state.ExitCode) -or $state.ExitCode -lt [int32]::MinValue -or $state.ExitCode -gt [int32]::MaxValue) {
        throw 'Docker returned an incomplete or invalid container state. No clean exit or readiness was inferred.'
    }
    if ($policy.Name -isnot [string] -or $policy.Name -notin @('no', 'always', 'unless-stopped', 'on-failure') -or
        -not (Test-JsonInteger $policy.MaximumRetryCount) -or $policy.MaximumRetryCount -lt 0 -or $policy.MaximumRetryCount -gt [int32]::MaxValue) {
        throw 'Docker returned an incomplete or invalid restart policy. No policy was inferred or replaced.'
    }
    if ($null -ne $state.Health -and
        ($state.Health.Status -isnot [string] -or $state.Health.Status -notin @('starting', 'healthy', 'unhealthy'))) {
        throw 'Docker returned an invalid healthcheck state. Database readiness was not inferred.'
    }
    return [pscustomobject]@{
        id = $fullId.ToLowerInvariant(); state = $state.Status; running = [bool]$state.Running
        restarting = [bool]$state.Restarting; exitCode = [int]$state.ExitCode; oomKilled = [bool]$state.OOMKilled
        health = $(if ($state.Health) { $state.Health.Status } else { $null })
        restartName = $policy.Name; restartRetries = [int]$policy.MaximumRetryCount
    }
}

function Get-ServiceContainer([string]$Service) {
    $ids = @(Invoke-Docker @('ps', '--all', '--quiet',
        '--filter', ('label=com.docker.compose.project=' + $script:projectName),
        '--filter', ('label=com.docker.compose.service=' + $Service)))
    $ids = @($ids | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($ids.Count -ne 1) {
        throw ('Expected exactly one existing ' + $Service + ' container in project ' + $script:projectName + '; found ' + $ids.Count + '. Nothing will be created or recreated automatically.')
    }
    return Get-ContainerById $ids[0]
}

function Require-RunningGame {
    $game = Get-ServiceContainer 'server'
    if ($game.state -ne 'running' -or -not $game.running -or $game.restarting) {
        throw ('Game container is ' + $game.state + ', not ready. No save or shutdown request was sent.')
    }
    return $game
}

function Require-HealthyDatabase {
    $database = Get-ServiceContainer 'database'
    if ($database.state -ne 'running' -or $database.restarting -or $database.health -ne 'healthy') {
        throw ('Database is not ready (state=' + $database.state + ', health=' + $database.health + '). No game command was sent. Use explicit START after checking the existing database container.')
    }
    return $database
}

function Wait-HealthyDatabase([string]$ContainerId, [int]$TimeoutSeconds = 120) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $database = Get-ContainerById $ContainerId
        if ($database.state -ne 'running' -or $database.restarting) {
            throw ('Existing database did not stay running: ' + $database.state + '. Inspect its logs; no replacement database was created.')
        }
        if ($database.health -eq 'healthy') { return }
        if (-not $database.health) { throw 'The existing database has no healthcheck. Readiness cannot be confirmed safely.' }
        Start-Sleep -Seconds 1
    }
    throw 'The existing database did not become healthy. The game was not started.'
}

function Assert-ChannelIdle {
    if (-not (Test-Path -LiteralPath $script:data -PathType Container)) { throw 'Missing existing server data directory.' }
    foreach ($name in @('tibiasp_launcher.request', 'tibiasp_launcher.processing')) {
        if (Test-Path -LiteralPath (Join-Path $script:data $name)) {
            throw ('Pending command evidence exists: ' + $name + '. No command was overwritten. Keep the file and logs; inspect/recover it only while the game is verified stopped.')
        }
    }
}

function Read-ChannelResponse([string]$Path) {
    $file = $null
    $reader = $null
    try {
        $sharing = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $file = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $sharing)
        $reader = New-Object IO.StreamReader($file, [Text.Encoding]::UTF8, $true)
        return $reader.ReadToEnd().Trim()
    } catch [IO.IOException] { return $null }
    finally {
        if ($reader) { $reader.Dispose() }
        elseif ($file) { $file.Dispose() }
    }
}

function Send-LauncherCommand([string]$Command, [string]$Expected, [string]$ContainerId, [int]$TimeoutSeconds = 45) {
    Assert-ChannelIdle
    $id = [guid]::NewGuid().ToString('N')
    $request = Join-Path $script:data 'tibiasp_launcher.request'
    $processing = Join-Path $script:data 'tibiasp_launcher.processing'
    $response = Join-Path $script:data 'tibiasp_launcher.response'
    $temporary = Join-Path $script:data ('tibiasp_launcher.' + $id + '.tmp')
    try {
        [IO.File]::WriteAllText($temporary, ($Command + ' ' + $id + "`n"), [Text.Encoding]::ASCII)
        # Same-directory rename publishes a complete request. Never overwrite one.
        [IO.File]::Move($temporary, $request)
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
    Note ('Sent ' + $Command + ' (' + $id + '). Waiting for engine acknowledgement.')
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $acknowledged = $false
    while ($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if (Test-Path -LiteralPath $response -PathType Leaf) {
            $text = Read-ChannelResponse $response
            if ($text -match ('^' + $id + ' (READY|SAVE_DONE|SHUTDOWN_ACCEPTED|ERROR)(?: (.*))?$')) {
                $status = $Matches[1]
                $detail = $Matches[2]
                if ($status -eq 'ERROR') { throw ('Engine rejected ' + $Command + ': ' + $detail + '. Request evidence was retained when available.') }
                if ($status -ne $Expected) { throw ('Unexpected matching acknowledgement for ' + $Command + ': ' + $status) }
                $acknowledged = $true
            }
        }
        # Lua publishes ACK before releasing processing. Do not race the next command.
        if ($acknowledged -and -not (Test-Path -LiteralPath $processing) -and -not (Test-Path -LiteralPath $request)) {
            Note ('Engine acknowledged ' + $Command + ': ' + $Expected)
            return
        }
        $game = Get-ContainerById $ContainerId
        if ($game.state -ne 'running' -or -not $game.running -or $game.restarting) {
            # The engine may publish its final ACK and exit between the read
            # above and this inspection. Re-read once before declaring failure.
            if ($Command -eq 'SHUTDOWN' -and $game.state -eq 'exited' -and -not $game.restarting) {
                $finalText = Read-ChannelResponse $response
                if ($finalText -eq ($id + ' ' + $Expected) -and
                    -not (Test-Path -LiteralPath $processing) -and -not (Test-Path -LiteralPath $request)) {
                    Note ('Engine acknowledged ' + $Command + ': ' + $Expected)
                    return
                }
            }
            throw ('Game became ' + $game.state + ' before a complete matching ' + $Expected + ' acknowledgement. Command files were retained for diagnosis.')
        }
        Start-Sleep -Milliseconds 200
    }
    throw ('No complete matching ' + $Expected + ' acknowledgement within ' + $TimeoutSeconds + ' seconds. No forced stop was performed. Keep the command files and Docker logs for diagnosis.')
}

function Read-RestartPolicy {
    if (-not (Test-Path -LiteralPath $script:policyFile -PathType Leaf)) { return $null }
    $record = [IO.File]::ReadAllText($script:policyFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($record.schema -ne 1 -or $record.project -ne $script:projectName -or
        -not [string]::Equals([string]$record.composePath, [IO.Path]::GetFullPath($script:compose), [StringComparison]::OrdinalIgnoreCase) -or
        $record.name -notin @('no', 'always', 'unless-stopped', 'on-failure') -or
        $null -eq $record.retries -or [int]$record.retries -lt 0) {
        throw 'Saved restart-policy evidence is invalid or belongs to another installation. It was not overwritten.'
    }
    return $record
}

function Save-RestartPolicy($Game) {
    $record = Read-RestartPolicy
    if ($record) {
        if ($Game.restartName -notin @('no', $record.name)) {
            throw 'Current restart policy conflicts with the saved policy. Resolve the difference before changing the container.'
        }
        return $record
    }
    if ($Game.restartName -notin @('no', 'always', 'unless-stopped', 'on-failure')) { throw 'Unsupported existing restart policy; refusing to replace it.' }
    New-Item -ItemType Directory -Path $script:controlDir -Force | Out-Null
    $record = [pscustomobject]@{
        schema = 1; project = $script:projectName; composePath = [IO.Path]::GetFullPath($script:compose)
        sourceContainerId = $Game.id; name = $Game.restartName; retries = [int]$Game.restartRetries
    }
    $temporary = $script:policyFile + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, ($record | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
        [IO.File]::Move($temporary, $script:policyFile)
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
    return $record
}

function Disable-Restart([string]$ContainerId) {
    $null = Invoke-Docker @('update', '--restart=no', $ContainerId)
    $check = Get-ContainerById $ContainerId
    if ($check.restartName -ne 'no') { throw 'Docker did not confirm restart=no. Shutdown was not requested.' }
}

function Restore-RestartAfterReady($Game) {
    $record = Read-RestartPolicy
    if (-not $record) { return }
    if ($Game.restartName -notin @('no', $record.name)) { throw 'Restart policy changed externally; saved policy was not applied.' }
    $policy = [string]$record.name
    if ($policy -eq 'on-failure' -and [int]$record.retries -gt 0) { $policy += ':' + [int]$record.retries }
    $null = Invoke-Docker @('update', ('--restart=' + $policy), $Game.id)
    $check = Get-ContainerById $Game.id
    if ($check.restartName -ne $record.name -or [int]$check.restartRetries -ne [int]$record.retries) {
        throw 'Docker did not confirm restoration of the original restart policy. Saved evidence was retained.'
    }
    Remove-Item -LiteralPath $script:policyFile -Force
    Note ('Original restart policy restored after PING READY: ' + $policy)
}

function Start-ExistingInstallation {
    Wait-Docker
    $game = Get-ServiceContainer 'server'
    $database = Get-ServiceContainer 'database'
    if ($game.state -eq 'running' -and $game.running -and -not $game.restarting) {
        $null = Require-HealthyDatabase
        Send-LauncherCommand 'PING' 'READY' $game.id
        Restore-RestartAfterReady (Get-ContainerById $game.id)
        Note 'The existing game is already ready; it was not restarted.'
        return
    }
    if ($game.state -notin @('exited', 'created') -or $game.running -or $game.restarting) {
        throw ('Game container is ' + $game.state + '. It was not restarted or recreated.')
    }
    Assert-ChannelIdle
    if ($database.state -in @('exited', 'created') -and -not $database.running -and -not $database.restarting) {
        $null = Invoke-Docker @('start', $database.id)
        Note 'Started the existing database container with its existing volume.'
    } elseif ($database.state -ne 'running' -or $database.restarting) {
        throw ('Database is ' + $database.state + '. No replacement container or database was created.')
    }
    Wait-HealthyDatabase $database.id
    $check = Get-ServiceContainer 'server'
    if ($check.id -ne $game.id -or $check.state -notin @('exited', 'created') -or $check.running -or $check.restarting) {
        throw 'Game state changed while the database was starting. No game recreation was attempted.'
    }
    $null = Save-RestartPolicy $check
    New-Item -ItemType Directory -Path $script:controlDir -Force | Out-Null
    $override = Join-Path $script:controlDir ('server-start-' + [guid]::NewGuid().ToString('N') + '.yaml')
    try {
        # Reconcile only the stopped game with an image built by the updater.
        # No dependencies, seed services, databases, builds or pulls are run here.
        [IO.File]::WriteAllText($override, "services:`n  server:`n    restart: `"no`"`n", [Text.Encoding]::ASCII)
        $null = Compose @('up', '--no-deps', '--no-build', '--pull', 'never', '--detach', 'server') $override
        $game = Require-RunningGame
        Send-LauncherCommand 'PING' 'READY' $game.id 90
        Restore-RestartAfterReady (Get-ContainerById $game.id)
    } finally {
        if (Test-Path -LiteralPath $override) { Remove-Item -LiteralPath $override -Force }
    }
    Note 'Game readiness confirmed by PING READY. Database/seed services were not recreated.'
}

function Save-ExistingWorld {
    Require-Docker
    $game = Require-RunningGame
    $null = Require-HealthyDatabase
    Send-LauncherCommand 'PING' 'READY' $game.id
    Send-LauncherCommand 'SAVE' 'SAVE_DONE' $game.id
    $script:operationResult.saveConfirmed = $true
    Note 'World save confirmed by matching SAVE_DONE.'
}

function Stop-ExistingWorld {
    Require-Docker
    $game = Require-RunningGame
    $null = Require-HealthyDatabase
    Send-LauncherCommand 'PING' 'READY' $game.id
    Send-LauncherCommand 'SAVE' 'SAVE_DONE' $game.id
    $script:operationResult.saveConfirmed = $true
    $game = Get-ContainerById $game.id
    $null = Save-RestartPolicy $game
    Disable-Restart $game.id
    # Do not restore in finally: even a failed/slow shutdown must not restart the game.
    Send-LauncherCommand 'SHUTDOWN' 'SHUTDOWN_ACCEPTED' $game.id
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($clock.Elapsed.TotalSeconds -lt 75) {
        $check = Get-ContainerById $game.id
        if ($check.state -eq 'exited' -and -not $check.running -and -not $check.restarting) {
            if ($check.exitCode -ne 0 -or $check.oomKilled) {
                throw ('Game exited abnormally (exit=' + $check.exitCode + ', OOM=' + $check.oomKilled + '). Save was acknowledged, but safe shutdown is not confirmed. Restart remains disabled.')
            }
            $script:operationResult.stopConfirmed = $true
            Note 'Game exited after confirmed save. Database remains running; restart=no is retained until explicit START.'
            return
        }
        if ($check.restarting -or $check.state -notin @('running', 'exited')) {
            throw ('Unexpected state during shutdown: ' + $check.state + '. No forced stop was performed; restart policy was not restored.')
        }
        Start-Sleep -Milliseconds 500
    }
    throw 'Game did not exit within 75 seconds. It was not killed and restart policy was not restored. Keep logs and pending-command evidence.'
}

function Write-OperationResult([string]$Path) {
    if (-not $Path) { return }
    $fullPath = [IO.Path]::GetFullPath($Path)
    $directory = [IO.Path]::GetDirectoryName($fullPath)
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $temporary = Join-Path $directory ('.result-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temporary, ($script:operationResult | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
        [IO.File]::Move($temporary, $fullPath)
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Invoke-Main {
    $id = if ($OperationId) { $OperationId.ToLowerInvariant() } else { [guid]::NewGuid().ToString('N') }
    $script:operationResult = [pscustomobject]@{
        schema = 1; operationId = $id; action = $Action; success = $false
        saveConfirmed = $false; stopConfirmed = $false; message = ''
    }
    $mutex = $null
    $owned = $false
    $transcript = $false
    $exitCode = 1
    try {
        $mutex = New-Object Threading.Mutex($false, 'Local\TibiaSP.Real860.Control')
        try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { throw 'Another TibiaSP control or installation operation is active. Wait for it to finish.' }
        New-Item -ItemType Directory -Path $script:controlDir -Force | Out-Null
        Start-Transcript -LiteralPath (Join-Path $script:controlDir 'DIAGNOSTYKA_REAL860.log') -Force | Out-Null
        $transcript = $true
        Note ('Action: ' + $Action + '; operation: ' + $id)
        switch ($Action) {
            'start' { Start-ExistingInstallation }
            'save' { Save-ExistingWorld }
            'safestop' { Stop-ExistingWorld }
            'stop' { Stop-ExistingWorld }
            'status' {
                Require-Docker
                foreach ($service in @('database', 'server')) {
                    $value = Get-ServiceContainer $service
                    Note ($service + ': state=' + $value.state + ', health=' + $value.health + ', restart=' + $value.restartName)
                }
            }
            'logs' { Require-Docker; Compose @('logs', '--tail', '100', 'server') | ForEach-Object { Write-Host $_ } }
            'diagnose' {
                Require-Docker
                foreach ($service in @('database', 'server')) {
                    $value = Get-ServiceContainer $service
                    Note ($service + ': state=' + $value.state + ', health=' + $value.health + ', restart=' + $value.restartName)
                }
                foreach ($name in @('tibiasp_launcher.request', 'tibiasp_launcher.processing', 'tibiasp_launcher.response')) {
                    Note ($name + ': exists=' + (Test-Path -LiteralPath (Join-Path $script:data $name)))
                }
            }
        }
        $script:operationResult.success = $true
        $script:operationResult.message = 'Operation completed with verified preconditions and acknowledgements.'
        $exitCode = 0
    } catch {
        $script:operationResult.message = $_.Exception.Message
        Note ('ERROR: ' + $_.Exception.Message)
    } finally {
        if ($transcript) { try { Stop-Transcript | Out-Null } catch { } }
        try { Write-OperationResult $ResultFile }
        catch { Write-Host ('ERROR: Could not write final operation result: ' + $_.Exception.Message); $exitCode = 1 }
        if ($owned) { $mutex.ReleaseMutex() }
        if ($mutex) { $mutex.Dispose() }
    }
    return $exitCode
}

# Dot-sourcing exposes functions for isolated tests without running Docker.
if ($MyInvocation.InvocationName -ne '.') { exit (Invoke-Main) }
