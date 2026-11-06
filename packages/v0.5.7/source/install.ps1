# TibiaSP v0.5.7: install only the launcher/control files, with verified rollback.
param([Parameter(Mandatory=$true)][string]$TargetRoot)
$ErrorActionPreference = 'Stop'
$version = '0.5.7'
$root = [IO.Path]::GetFullPath($TargetRoot).TrimEnd([char[]]@('\', '/'))
$allowed = @('TibiaSP_Launcher.ps1', 'TIBIA_REAL860.ps1', 'silnik-8.60/server/data/globalevents/scripts/tibiasp_launcher_commands.lua')
$channelNames = @('tibiasp_launcher.request', 'tibiasp_launcher.processing', 'tibiasp_launcher.response')
$dataRelative = 'silnik-8.60/server/data'
$changed = New-Object 'System.Collections.Generic.List[string]'
$removedChannel = New-Object 'System.Collections.Generic.List[string]'
$mutex = $null
$ownsMutex = $false
$backup = $null
$backupHashes = @{}
$initialHashes = @{}

function Say([string]$message) { Write-Host ('[TibiaSP ' + $version + '] ' + $message) }
function Ensure([bool]$condition, [string]$message) { if (-not $condition) { throw $message } }
function Hash([string]$path) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }
function LocalPath([string]$basePath, [string]$relative) {
    $path = [IO.Path]::GetFullPath((Join-Path $basePath $relative))
    $prefix = $basePath.TrimEnd([char[]]@('\', '/')) + [IO.Path]::DirectorySeparatorChar
    Ensure ($path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) 'Sciezka wychodzi poza folder instalacji.'
    return $path
}
function NoLinks([string]$path, [string]$basePath) {
    $current = [IO.Path]::GetFullPath($path)
    $stop = [IO.Path]::GetFullPath($basePath).TrimEnd([char[]]@('\', '/'))
    while ($true) {
        $item = Get-Item -LiteralPath $current -Force
        Ensure (-not [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) 'Odmowa pracy na dowiazaniu.'
        if ($current.TrimEnd([char[]]@('\', '/')) -eq $stop) { break }
        $parent = Split-Path -Parent $current
        Ensure ([bool]$parent -and $parent -ne $current) 'Nie mozna zweryfikowac katalogow instalacji.'
        $current = $parent
    }
}
function AssertGameStopped([string]$dockerPath) {
    $ids = @(& $dockerPath ps -aq --filter 'label=com.docker.compose.project=tibiasp-real860' --filter 'label=com.docker.compose.service=server')
    Ensure ($LASTEXITCODE -eq 0) 'Nie mozna odczytac kontenerow Dockera.'
    $regular = @()
    foreach ($id in $ids) {
        if (-not ([string]$id).Trim()) { continue }
        $labelText = & $dockerPath inspect --format '{{json .Config.Labels}}' $id
        Ensure ($LASTEXITCODE -eq 0) 'Nie mozna sprawdzic etykiet kontenera.'
        $labels = ($labelText -join "`n") | ConvertFrom-Json
        $stateText = & $dockerPath inspect --format '{{json .State}}' $id
        Ensure ($LASTEXITCODE -eq 0) 'Nie mozna potwierdzic zatrzymania kontenera.'
        $state = ($stateText -join "`n") | ConvertFrom-Json
        Ensure ($state.Running -eq $false -and $state.Restarting -eq $false -and @('exited', 'created') -contains $state.Status) 'Zatrzymaj gre przed instalacja. Kontener nadal dziala lub jego stan jest niepewny.'
        if ($labels.'com.docker.compose.oneoff' -eq 'True') { continue }
        $regular += $id
    }
    Ensure ($regular.Count -eq 1) 'Wymagany jest jeden istniejacy kontener uslugi server projektu tibiasp-real860.'
}
function CheckChannel([string]$path, [string]$name) {
    $item = Get-Item -LiteralPath $path -Force
    Ensure (-not $item.PSIsContainer -and $item.Length -le 8192) 'Nieznany plik kanalu polecen; potrzebna diagnostyka.'
    $text = ([IO.File]::ReadAllText($path)).Trim()
    if ($name -eq 'tibiasp_launcher.response') {
        # The old writer could leave an empty response after opening/truncating it.
        Ensure ($text -eq '' -or $text -eq 'SAVE_DONE' -or $text -match '\A[0-9a-fA-F]{32} (READY|SAVE_DONE|SHUTDOWN_ACCEPTED|ERROR(?: [^\r\n]+)?)\z') 'Nieznana odpowiedz kanalu; pliki pozostawiono bez zmian.'
    } else {
        Ensure ($text -match '\A(SAVE|SHUTDOWN|PING)( [0-9a-fA-F]{32})?\z') 'Nieznane oczekujace polecenie; pliki pozostawiono bez zmian.'
    }
}

try {
    Ensure (Test-Path -LiteralPath $root -PathType Container) 'Brak folderu TibiaSP.'
    Ensure (Test-Path -LiteralPath (Join-Path $root 'URUCHOM_TIBIASP.vbs') -PathType Leaf) 'Brak launchera TibiaSP.'
    Ensure ([bool]$env:LOCALAPPDATA) 'Brak LOCALAPPDATA.'
    $mutex = New-Object Threading.Mutex($false, 'Local\TibiaSP.Real860.Control')
    try { $ownsMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
    Ensure $ownsMutex 'Trwa operacja serwera. Poczekaj na jej zakonczenie.'

    # The old helper has no mutex; refuse installation while it is executing.
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $active = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' AND CommandLine LIKE '%TIBIA_REAL860.ps1%'" -ErrorAction Stop)
        Ensure ($active.Count -eq 0) 'TIBIA_REAL860.ps1 nadal dziala. Poczekaj na zakonczenie operacji.'
    }
    $command = Get-Command docker.exe -ErrorAction SilentlyContinue
    $docker = if ($command) { $command.Source } else { 'C:\Program Files\Docker\Docker\resources\bin\docker.exe' }
    Ensure ([bool]$docker -and (Test-Path -LiteralPath $docker -PathType Leaf)) 'Brak docker.exe.'
    & $docker info --format '{{.ServerVersion}}' | Out-Null
    Ensure ($LASTEXITCODE -eq 0) 'Docker Desktop nie jest gotowy.'
    AssertGameStopped $docker

    $manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'file-hashes.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Ensure ($manifest.version -eq $version -and @($manifest.files).Count -eq $allowed.Count) 'Nieprawidlowy manifest plikow.'
    $seen = @{}
    foreach ($entry in $manifest.files) {
        $relative = [string]$entry.path
        Ensure ($allowed -contains $relative -and -not $seen.ContainsKey($relative)) 'Nieprawidlowa sciezka w manifescie.'
        $seen[$relative] = $true
        $target = LocalPath $root $relative
        $payload = LocalPath (Join-Path $PSScriptRoot 'payload') $relative
        NoLinks $target $root
        NoLinks $payload (Join-Path $PSScriptRoot 'payload')
        $actual = Hash $target
        Ensure ($actual -eq $entry.new -or @($entry.old) -contains $actual) ('Nieznana wersja pliku: ' + $relative + '. Nic nie nadpisano.')
        $initialHashes[$relative] = $actual
        Ensure ((Hash $payload) -eq $entry.new) ('Niezgodny SHA-256 pakietu: ' + $relative)
        if ($relative.EndsWith('.ps1')) {
            $tokens = $null; $parseErrors = $null
            [Management.Automation.Language.Parser]::ParseFile($payload, [ref]$tokens, [ref]$parseErrors) | Out-Null
            Ensure (@($parseErrors).Count -eq 0) ('Skrypt jest niezgodny z tym PowerShell: ' + $relative)
        }
    }
    $eventPath = LocalPath $root 'silnik-8.60/server/data/globalevents/globalevents.xml'
    NoLinks $eventPath $root
    [xml]$events = Get-Content -LiteralPath $eventPath -Raw
    $registered = @($events.globalevents.globalevent | Where-Object { $_.script -eq 'tibiasp_launcher_commands.lua' })
    Ensure ($registered.Count -eq 1 -and [int]$registered[0].interval -gt 0) 'Brak jednoznacznej rejestracji eventu Lua; instalacja przerwana.'
    $channel = @()
    foreach ($name in $channelNames) {
        $relative = $dataRelative + '/' + $name
        $path = LocalPath $root $relative
        if (Test-Path -LiteralPath $path) {
            NoLinks $path $root
            CheckChannel $path $name
            $initialHashes[$relative] = Hash $path
            $channel += $relative
        }
    }

    $backup = Join-Path $env:LOCALAPPDATA ('TibiaSP/Backups/SaveStatus_' + $version + '_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    foreach ($relative in @($allowed) + @($channel)) {
        $source = LocalPath $root $relative
        $destination = LocalPath $backup $relative
        NoLinks $source $root
        Ensure ((Hash $source) -eq $initialHashes[$relative]) 'Plik zmienil sie po weryfikacji; nic nie nadpisano.'
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $destination -Force
        $backupHashes[$relative] = $initialHashes[$relative]
        Ensure ((Hash $source) -eq $initialHashes[$relative]) 'Plik zmienil sie podczas wykonywania kopii.'
        Ensure ((Hash $destination) -eq $backupHashes[$relative]) ('Niezgodna kopia: ' + $relative)
    }
    $backupHashes | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $backup 'backup-hashes.json') -Encoding UTF8
    # Recheck immediately before changing code or retiring pending commands.
    AssertGameStopped $docker
    foreach ($entry in $manifest.files) {
        $target = LocalPath $root ([string]$entry.path)
        NoLinks $target $root
        Ensure ((Hash $target) -eq $backupHashes[[string]$entry.path]) 'Plik zmienil sie podczas przygotowania instalacji.'
        if ((Hash $target) -eq $entry.new) { continue }
        $changed.Add([string]$entry.path)
        Copy-Item -LiteralPath (LocalPath (Join-Path $PSScriptRoot 'payload') ([string]$entry.path)) -Destination $target -Force
        Ensure ((Hash $target) -eq $entry.new) ('Blad zapisu: ' + $entry.path)
    }
    foreach ($relative in $channel) {
        $path = LocalPath $root $relative
        Ensure ((Hash $path) -eq $backupHashes[$relative]) 'Polecenie zmienilo sie podczas instalacji.'
        $removedChannel.Add($relative)
        Remove-Item -LiteralPath $path -Force
    }
    Say ('Kopia plikow i rozpoznanych starych polecen: ' + $backup)
    Say 'Zainstalowano obsluge zapisu i statusu. Zamknij i ponownie otworz launcher.'
    Say 'Serwer pozostaje zatrzymany. Przy nastepnym starcie najpierw sprawdzona zostanie istniejaca baza.'
    Write-Host 'TIBIASP_UPDATE_OK'
} catch {
    Say ('BLAD: ' + $_.Exception.Message)
    $restored = $true
    foreach ($relative in @($changed.ToArray()) + @($removedChannel.ToArray())) {
        try {
            Copy-Item -LiteralPath (LocalPath $backup $relative) -Destination (LocalPath $root $relative) -Force
            Ensure ((Hash (LocalPath $root $relative)) -eq $backupHashes[$relative]) 'Niezgodny SHA-256 po cofnieciu.'
        } catch { $restored = $false; Say ('BLAD COFANIA: ' + $relative) }
    }
    if ($changed.Count -gt 0 -or $removedChannel.Count -gt 0) {
        if ($restored) { Say 'Przywrocono poprzednie pliki i kanal polecen.' }
        else { Say ('Niepelne cofniecie; zachowaj kopie: ' + $backup) }
    }
    exit 1
} finally {
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    if ($null -ne $mutex) { $mutex.Dispose() }
}
exit 0
