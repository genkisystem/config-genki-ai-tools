$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$RepositoryRawUrl = 'https://raw.githubusercontent.com/genkisystem/config-genki-ai-tools/main'
$FqVersion = '0.17.0'

function Get-EnvironmentValue {
    param([string]$Name, [string]$DefaultValue)

    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $DefaultValue
    }
    return $value
}

function Download-File {
    param([string]$Url, [string]$Destination)

    Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Destination
}

function Backup-File {
    if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
        $timestamp = Get-Date -Format 'yyyyMMddHHmmss'
        $backup = "$ConfigPath.bak.$timestamp"
        if (Test-Path -LiteralPath $backup) {
            $backup = "$backup.$PID"
        }
        Copy-Item -LiteralPath $ConfigPath -Destination $backup
        Write-Host "Backup: $backup"
    }
}

function Install-Fq {
    $configuredPath = [Environment]::GetEnvironmentVariable('GENKI_FQ_PATH')
    if (-not [string]::IsNullOrWhiteSpace($configuredPath)) {
        if (-not (Test-Path -LiteralPath $configuredPath -PathType Leaf)) {
            throw "GENKI_FQ_PATH does not exist: $configuredPath"
        }
        return $configuredPath
    }

    $architecture = if ($env:PROCESSOR_ARCHITEW6432) {
        $env:PROCESSOR_ARCHITEW6432
    }
    else {
        $env:PROCESSOR_ARCHITECTURE
    }

    switch ($architecture.ToUpperInvariant()) {
        'AMD64' {
            $asset = "fq_${FqVersion}_windows_amd64.zip"
            $expectedHash = '9a84c41a4c088d7df748c8b210afbb3b5307cf69c2605d86aead595c6785fd97'
        }
        'ARM64' {
            $asset = "fq_${FqVersion}_windows_arm64.zip"
            $expectedHash = '488346a0935e6519e48a29e655b18d6af2f30412f1faebb0e98c9d27c0ed2b91'
        }
        default {
            throw "fq does not provide a supported Windows binary for $architecture"
        }
    }

    $archive = Join-Path $TempDir $asset
    Download-File "https://github.com/wader/fq/releases/download/v$FqVersion/$asset" $archive

    $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
    if ($actualHash -ne $expectedHash) {
        throw "Checksum verification failed for $asset"
    }

    $extractDirectory = Join-Path $TempDir 'fq'
    Expand-Archive -LiteralPath $archive -DestinationPath $extractDirectory -Force
    $executable = Get-ChildItem -LiteralPath $extractDirectory -Filter 'fq.exe' -File -Recurse | Select-Object -First 1
    if ($null -eq $executable) {
        throw "fq.exe was not found in $asset"
    }

    return $executable.FullName
}

function Prepare-TomlFile {
    param(
        [string]$FqPath,
        [string]$Path,
        [string]$Label
    )

    $hasContent = @(Get-Content -LiteralPath $Path | Where-Object {
        $_ -notmatch '^\s*(?:#.*)?$'
    }).Count -gt 0

    if ($hasContent) {
        $validationOutput = & $FqPath -V '.' $Path 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "$Label is not valid TOML.`n$($validationOutput -join "`n")"
        }
    }
    else {
        [IO.File]::WriteAllText($Path, "{}`n", [Text.UTF8Encoding]::new($false))
    }
}

function Write-TokenInput {
    param(
        [string]$FqPath,
        [string]$CurrentPath,
        [string]$TokenInputPath,
        [string]$TemporaryDirectory
    )

    [IO.File]::WriteAllText($TokenInputPath, "null`n", [Text.UTF8Encoding]::new($false))

    $tokenExistsQuery = @'
has("model_providers")
and (.model_providers | type == "object")
and (.model_providers | has("genki"))
and (.model_providers.genki | type == "object")
and (.model_providers.genki | has("experimental_bearer_token"))
'@

    $tokenExistsQueryPath = Join-Path $TemporaryDirectory 'token-exists.fq'
    [IO.File]::WriteAllText($tokenExistsQueryPath, $tokenExistsQuery, [Text.UTF8Encoding]::new($false))
    $tokenExistsOutput = & $FqPath -r -f $tokenExistsQueryPath $CurrentPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Could not inspect the existing Genki provider configuration.`n$($tokenExistsOutput -join "`n")"
    }

    $tokenExists = ($tokenExistsOutput -join '').Trim().ToLowerInvariant()
    if ($tokenExists -eq 'true') {
        return
    }
    if ($tokenExists -ne 'false') {
        throw 'Could not determine whether the Genki bearer token already exists.'
    }

    $token = [Environment]::GetEnvironmentVariable('GENKI_CODEX_EXPERIMENTAL_BEARER_TOKEN')
    if ([string]::IsNullOrEmpty($token)) {
        $secureToken = Read-Host 'Enter Genki experimental bearer token' -AsSecureString
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
        try {
            $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
        }
        finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
        }
    }

    if ([string]::IsNullOrEmpty($token)) {
        return
    }

    $tokenRawPath = Join-Path $TemporaryDirectory 'token.txt'
    [IO.File]::WriteAllText($tokenRawPath, $token, [Text.UTF8Encoding]::new($false))
    try {
        $encodedToken = & $FqPath -R -s '.' $tokenRawPath 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Could not encode the Genki bearer token.`n$($encodedToken -join "`n")"
        }
        [IO.File]::WriteAllText($TokenInputPath, (($encodedToken -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
    }
    finally {
        Remove-Item -LiteralPath $tokenRawPath -Force -ErrorAction SilentlyContinue
        $token = $null
    }
}

function Write-BaseUrlInput {
    param(
        [string]$FqPath,
        [string]$CurrentPath,
        [string]$BaseUrlInputPath,
        [string]$TemporaryDirectory
    )

    [IO.File]::WriteAllText($BaseUrlInputPath, "null`n", [Text.UTF8Encoding]::new($false))

    $baseUrlExistsQuery = @'
has("model_providers")
and (.model_providers | type == "object")
and (.model_providers | has("genki"))
and (.model_providers.genki | type == "object")
and (.model_providers.genki | has("base_url"))
and (.model_providers.genki.base_url | type == "string")
and (.model_providers.genki.base_url | test("\\S"))
'@

    $baseUrlExistsQueryPath = Join-Path $TemporaryDirectory 'base-url-exists.fq'
    [IO.File]::WriteAllText($baseUrlExistsQueryPath, $baseUrlExistsQuery, [Text.UTF8Encoding]::new($false))
    $baseUrlExistsOutput = & $FqPath -r -f $baseUrlExistsQueryPath $CurrentPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Could not inspect the existing Genki provider base URL.`n$($baseUrlExistsOutput -join "`n")"
    }

    $baseUrlExists = ($baseUrlExistsOutput -join '').Trim().ToLowerInvariant()
    if ($baseUrlExists -eq 'true') {
        return
    }
    if ($baseUrlExists -ne 'false') {
        throw 'Could not determine whether the Genki provider base URL already has a value.'
    }

    $baseUrl = [Environment]::GetEnvironmentVariable('GENKI_CODEX_PROVIDER_BASE_URL')
    if ([string]::IsNullOrWhiteSpace($baseUrl)) {
        $baseUrl = Read-Host 'Enter Codex Genki provider base URL'
    }

    if ([string]::IsNullOrWhiteSpace($baseUrl)) {
        return
    }

    $baseUrlRawPath = Join-Path $TemporaryDirectory 'base-url.txt'
    [IO.File]::WriteAllText($baseUrlRawPath, $baseUrl, [Text.UTF8Encoding]::new($false))
    try {
        $encodedBaseUrl = & $FqPath -R -s '.' $baseUrlRawPath 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Could not encode the Genki provider base URL.`n$($encodedBaseUrl -join "`n")"
        }
        [IO.File]::WriteAllText($BaseUrlInputPath, (($encodedBaseUrl -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
    }
    finally {
        Remove-Item -LiteralPath $baseUrlRawPath -Force -ErrorAction SilentlyContinue
        $baseUrl = $null
    }
}

$ConfigBaseUrl = (Get-EnvironmentValue 'GENKI_CONFIG_BASE_URL' $RepositoryRawUrl).TrimEnd('/')
$ConfigUrl = Get-EnvironmentValue 'GENKI_CODEX_CONFIG_URL' "$ConfigBaseUrl/codex/config.toml"
$DeleteUrl = Get-EnvironmentValue 'GENKI_CODEX_DELETE_URL' "$ConfigBaseUrl/codex/delete.toml"
$UserHome = [Environment]::GetFolderPath('UserProfile')
$CodexHome = Get-EnvironmentValue 'CODEX_HOME' (Join-Path $UserHome '.codex')
$ConfigPath = Get-EnvironmentValue 'CODEX_CONFIG_PATH' (Join-Path $CodexHome 'config.toml')

$TempDir = Join-Path ([IO.Path]::GetTempPath()) ("genki-codex-config-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $TempDir | Out-Null
$ActiveStage = $null

$FqQuery = @'
def manifest_paths:
  def descend($path):
    if type == "object" then
      to_entries[] | .key as $key | .value | descend($path + [$key])
    else
      $path
    end;
  descend([]);

def prune_empty_objects:
  walk(if type == "object" then with_entries(select(.value != {})) else . end);

.[0] as $current
| .[1] as $incoming
| .[3] as $prompted_token
| .[4] as $prompted_base_url
| (
    $incoming
    | if $prompted_token == null then
        delpaths([["model_providers", "genki", "experimental_bearer_token"]])
      else
        setpath(
          ["model_providers", "genki", "experimental_bearer_token"];
          $prompted_token
        )
      end
    | if $prompted_base_url == null then
        delpaths([["model_providers", "genki", "base_url"]])
      else
        setpath(
          ["model_providers", "genki", "base_url"];
          $prompted_base_url
        )
      end
  ) as $effective_incoming
| ($current * $effective_incoming) as $merged
| .[2] as $manifest
| reduce ($manifest | manifest_paths) as $path (
    $merged;
    ($manifest | getpath($path)) as $expected
    | (try getpath($path) catch null) as $actual
    | if (
        $expected == "__GENKI_DELETE_ANY__"
        or (($actual | type) == ($expected | type) and $actual == $expected)
      ) then
        delpaths([$path])
      else
        .
      end
  )
| prune_empty_objects
| to_toml
'@

try {
    $configSource = Join-Path $TempDir 'config.toml'
    $deleteSource = Join-Path $TempDir 'delete.toml'
    Write-Host 'Downloading managed Codex configuration...'
    Download-File $ConfigUrl $configSource
    Download-File $DeleteUrl $deleteSource
    $FqPath = Install-Fq

    $targetDirectory = Split-Path -Parent $ConfigPath
    New-Item -ItemType Directory -Force -Path $targetDirectory | Out-Null

    $current = Join-Path $TempDir 'current.toml'
    if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
        Copy-Item -LiteralPath $ConfigPath -Destination $current
    }
    else {
        [IO.File]::WriteAllText($current, '', [Text.UTF8Encoding]::new($false))
    }

    Prepare-TomlFile -FqPath $FqPath -Path $current -Label 'The existing Codex config file'
    Prepare-TomlFile -FqPath $FqPath -Path $configSource -Label 'The downloaded Codex config file'
    Prepare-TomlFile -FqPath $FqPath -Path $deleteSource -Label 'The downloaded Codex deletion file'

    $tokenInput = Join-Path $TempDir 'token.json'
    Write-TokenInput -FqPath $FqPath -CurrentPath $current -TokenInputPath $tokenInput -TemporaryDirectory $TempDir

    $baseUrlInput = Join-Path $TempDir 'base-url.json'
    Write-BaseUrlInput -FqPath $FqPath -CurrentPath $current -BaseUrlInputPath $baseUrlInput -TemporaryDirectory $TempDir

    $fqQueryPath = Join-Path $TempDir 'merge.fq'
    [IO.File]::WriteAllText($fqQueryPath, $FqQuery, [Text.UTF8Encoding]::new($false))
    $mergeOutput = & $FqPath -r -j -s -f $fqQueryPath $current $configSource $deleteSource $tokenInput $baseUrlInput 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Could not merge Codex config. The existing file was left unchanged.`n$($mergeOutput -join "`n")"
    }

    $ActiveStage = Join-Path $targetDirectory ('.genki-config-' + [Guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText($ActiveStage, (($mergeOutput -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))

    $validationOutput = & $FqPath -d toml -V '.' $ActiveStage 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Could not validate merged Codex config. The existing file was left unchanged.`n$($validationOutput -join "`n")"
    }

    Backup-File
    Move-Item -LiteralPath $ActiveStage -Destination $ConfigPath -Force
    $ActiveStage = $null

    Write-Host "Updated: $ConfigPath"
    Write-Host 'Codex configuration installed successfully. Managed values override matching local values.'
}
finally {
    if ($null -ne $ActiveStage) {
        Remove-Item -LiteralPath $ActiveStage -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $TempDir -Recurse -Force -ErrorAction SilentlyContinue
}
