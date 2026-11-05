# TibiaSP v0.5.6 - stamina and first-login equipment (minimal safe patch)
param([Parameter(Mandatory=$true)][string]$TargetRoot)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$version = '0.5.6'
$project = 'tibiasp-real860'
$server = Join-Path $TargetRoot 'silnik-8.60\server'
$compose = Join-Path $server 'compose.yaml'
$backup = Join-Path $env:LOCALAPPDATA ('TibiaSP\Backups\StaminaEQ_' + $version + '_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
$patchFile = Join-Path $PSScriptRoot 'patches.json'
$changed = New-Object 'System.Collections.Generic.List[string]'
$started = $false
$docker = $null
$utf8 = [System.Text.UTF8Encoding]::new($false, $true)

function Say([string]$msg) { Write-Host ('[TibiaSP ' + $version + '] ' + $msg) }
function Ensure([bool]$ok,[string]$msg) { if (-not $ok) { throw $msg } }
function Hash([string]$path) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }
function BytesHash([byte[]]$bytes) {
  $alg = [System.Security.Cryptography.SHA256]::Create()
  try { ([System.BitConverter]::ToString($alg.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() }
  finally { $alg.Dispose() }
}
function NoLink([string]$path) {
  $item = Get-Item -LiteralPath $path -Force
  Ensure (-not [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) ('Odmowa modyfikacji dowiazania: ' + $path)
}
function Compose([string[]]$parts) {
  & $script:docker compose -p $script:project -f $script:compose @parts
  Ensure ($LASTEXITCODE -eq 0) ('Docker Compose blad: ' + ($parts -join ' '))
}
try {
  Ensure (Test-Path -LiteralPath $compose -PathType Leaf) 'Brak compose.yaml.'
  Ensure (Test-Path -LiteralPath $patchFile -PathType Leaf) 'Brak patches.json.'
  Ensure (Test-Path -LiteralPath (Join-Path $TargetRoot 'URUCHOM_TIBIASP.vbs') -PathType Leaf) 'Brak launchera TibiaSP.'
  $cmd = Get-Command docker.exe -ErrorAction SilentlyContinue
  if ($cmd) { $docker = $cmd.Source }
  elseif (Test-Path -LiteralPath 'C:\Program Files\Docker\Docker\resources\bin\docker.exe') {
    $docker = 'C:\Program Files\Docker\Docker\resources\bin\docker.exe'
  }
  Ensure (-not [string]::IsNullOrWhiteSpace($docker)) 'Nie znaleziono docker.exe.'
  & $docker info --format '{{.ServerVersion}}' 2>$null | Out-Null
  Ensure ($LASTEXITCODE -eq 0) 'Docker Desktop nie jest gotowy.'
  $running = @(& $docker ps --filter 'label=com.docker.compose.project=tibiasp-real860' --format '{{.Names}}')
  Ensure ($LASTEXITCODE -eq 0) 'Nie mozna sprawdzic kontenerow.'
  Ensure (@($running | Where-Object { $_ -match '^tibiasp-real860-server-' }).Count -eq 0) 'Zatrzymaj serwer przed aktualizacja.'

  $patches = Get-Content -LiteralPath $patchFile -Raw -Encoding UTF8 | ConvertFrom-Json
  $files = @('config.lua','src/player.h','src/player.cpp','data/events/scripts/player.lua','data/creaturescripts/scripts/firstitems.lua')
  $status = @{}
  $newBytes = @{}
  foreach ($rel in $files) {
    $relative = $rel.Replace('/', '\')
    $target = Join-Path $server $relative
    Ensure (Test-Path -LiteralPath $target -PathType Leaf) ('Brak pliku: ' + $rel)
    NoLink $target
    $entry = $patches.PSObject.Properties[$rel].Value
    Ensure ($null -ne $entry) ('Brak danych poprawki: ' + $rel)
    $actual = Hash $target
    if ($actual -eq [string]$entry.new) { $status[$rel] = 'updated'; continue }
    Ensure (@($entry.old) -contains $actual) ('Nieznana wersja pliku: ' + $rel + '. Nic nie nadpisano.')
    $status[$rel] = 'old'
    if ($rel -eq 'data/creaturescripts/scripts/firstitems.lua') {
      $payload = Join-Path (Join-Path $PSScriptRoot 'payload') $relative
      Ensure (Test-Path -LiteralPath $payload -PathType Leaf) 'Brak pliku starter EQ.'
      NoLink $payload
      $bytes = [System.IO.File]::ReadAllBytes($payload)
    } else {
      $content = $utf8.GetString([System.IO.File]::ReadAllBytes($target))
      foreach ($change in $entry.replacements) {
        $before = [string]$change.before
        $after = [string]$change.after
        Ensure ($before.Length -gt 0) ('Pusty fragment poprawki: ' + $rel)
        $first = $content.IndexOf($before, [StringComparison]::Ordinal)
        Ensure ($first -ge 0) ('Brak fragmentu w: ' + $rel)
        Ensure ($content.LastIndexOf($before, [StringComparison]::Ordinal) -eq $first) ('Niejednoznaczny fragment: ' + $rel)
        $content = $content.Replace($before, $after)
      }
      $bytes = $utf8.GetBytes($content)
    }
    Ensure ((BytesHash $bytes) -eq [string]$entry.new) ('Hash po poprawce niezgodny: ' + $rel)
    $newBytes[$rel] = $bytes
  }
  Say 'Sprawdzono pliki i sumy SHA256. Dane postaci pozostana bez zmian.'
  Compose @('config','--quiet')
  New-Item -ItemType Directory -Path $backup -Force | Out-Null
  $started = $true
  foreach ($rel in $files) {
    $relative = $rel.Replace('/', '\')
    $target = Join-Path $server $relative
    $destination = Join-Path $backup $relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    Copy-Item -LiteralPath $target -Destination $destination -Force
    Ensure ((Hash $destination) -eq (Hash $target)) ('Kopia niezgodna: ' + $rel)
  }
  Say ('Utworzono kopie: ' + $backup)
  foreach ($rel in $files) {
    if ($status[$rel] -eq 'updated') { Say ('Juz poprawiony: ' + $rel); continue }
    $target = Join-Path $server $rel.Replace('/', '\')
    $changed.Add($rel)
    [System.IO.File]::WriteAllBytes($target, [byte[]]$newBytes[$rel])
    Ensure ((Hash $target) -eq [string]$patches.PSObject.Properties[$rel].Value.new) ('Nie udalo sie zapisac: ' + $rel)
    Say ('Poprawiono: ' + $rel)
  }
  Say 'Przebudowuje silnik Docker. Moze to potrwac kilka minut.'
  Compose @('build','server')
  Say 'Obraz zbudowany. Serwer pozostaje zatrzymany.'
  Say 'Stamina 42:00 widoczna; EQ tylko nowych postaci.'
  Say 'Baza danych, konta, boty, mapa i OTClient bez zmian.'
  Write-Host 'TIBIASP_UPDATE_OK'
  exit 0
} catch {
  Write-Host ('[TibiaSP 0.5.6] BLAD: ' + $_.Exception.Message)
  if ($started) {
    $restored = $true
    foreach ($rel in $changed) {
      try {
        $relative = $rel.Replace('/', '\')
        Copy-Item -LiteralPath (Join-Path $backup $relative) -Destination (Join-Path $server $relative) -Force
      } catch { $restored = $false; Write-Host ('[TibiaSP 0.5.6] BLAD COFANIA: ' + $rel) }
    }
    if ($restored) { Say 'Przywrocono poprzednie pliki po bledzie.' }
    else { Say ('Niepelne cofniecie! Nie uruchamiaj serwera. Kopie: ' + $backup) }
    Say ('Kopie: ' + $backup)
  }
  exit 1
}
