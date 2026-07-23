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
    if (Test-Path -LiteralPath $SettingsPath -PathType Leaf) {
        $timestamp = Get-Date -Format 'yyyyMMddHHmmss'
        $backup = "$SettingsPath.bak.$timestamp"
        if (Test-Path -LiteralPath $backup) {
            $backup = "$backup.$PID"
        }
        Copy-Item -LiteralPath $SettingsPath -Destination $backup
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

function Assert-ValidJsonObjectFile {
    param(
        [string]$FqPath,
        [string]$Path,
        [string]$Label,
        [string]$QueryPath
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        # Windows PowerShell promotes native stderr to an error record when the
        # global preference is Stop. Capture fq's parser error so the caller
        # receives the contextual validation message below.
        $ErrorActionPreference = 'Continue'
        $validationOutput = & $FqPath -R -s -V -f $QueryPath $Path 2>&1
        $validationExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($validationExitCode -ne 0) {
        throw "$Label is not a valid JSON object.`n$($validationOutput -join "`n")"
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
has("env")
and (.env | type == "object")
and (.env | has("ANTHROPIC_AUTH_TOKEN"))
'@

    $tokenExistsQueryPath = Join-Path $TemporaryDirectory 'token-exists.fq'
    [IO.File]::WriteAllText($tokenExistsQueryPath, $tokenExistsQuery, [Text.UTF8Encoding]::new($false))
    $tokenExistsOutput = & $FqPath -r -f $tokenExistsQueryPath $CurrentPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Could not inspect the existing Claude authentication configuration.`n$($tokenExistsOutput -join "`n")"
    }

    $tokenExists = ($tokenExistsOutput -join '').Trim().ToLowerInvariant()
    if ($tokenExists -eq 'true') {
        return
    }
    if ($tokenExists -ne 'false') {
        throw 'Could not determine whether ANTHROPIC_AUTH_TOKEN already exists.'
    }

    $token = [Environment]::GetEnvironmentVariable('GENKI_CLAUDE_ANTHROPIC_AUTH_TOKEN')
    if ([string]::IsNullOrEmpty($token)) {
        $secureToken = Read-Host 'Enter Claude ANTHROPIC_AUTH_TOKEN' -AsSecureString
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
            throw "Could not encode ANTHROPIC_AUTH_TOKEN.`n$($encodedToken -join "`n")"
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
has("env")
and (.env | type == "object")
and (.env | has("ANTHROPIC_BASE_URL"))
and (.env.ANTHROPIC_BASE_URL | type == "string")
and (.env.ANTHROPIC_BASE_URL | test("\\S"))
'@

    $baseUrlExistsQueryPath = Join-Path $TemporaryDirectory 'base-url-exists.fq'
    [IO.File]::WriteAllText($baseUrlExistsQueryPath, $baseUrlExistsQuery, [Text.UTF8Encoding]::new($false))
    $baseUrlExistsOutput = & $FqPath -r -f $baseUrlExistsQueryPath $CurrentPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Could not inspect the existing Claude base URL configuration.`n$($baseUrlExistsOutput -join "`n")"
    }

    $baseUrlExists = ($baseUrlExistsOutput -join '').Trim().ToLowerInvariant()
    if ($baseUrlExists -eq 'true') {
        return
    }
    if ($baseUrlExists -ne 'false') {
        throw 'Could not determine whether ANTHROPIC_BASE_URL already has a value.'
    }

    $baseUrl = [Environment]::GetEnvironmentVariable('GENKI_CLAUDE_ANTHROPIC_BASE_URL')
    if ([string]::IsNullOrWhiteSpace($baseUrl)) {
        $baseUrl = Read-Host 'Enter Claude ANTHROPIC_BASE_URL'
    }

    if ([string]::IsNullOrWhiteSpace($baseUrl)) {
        return
    }

    $baseUrlRawPath = Join-Path $TemporaryDirectory 'base-url.txt'
    [IO.File]::WriteAllText($baseUrlRawPath, $baseUrl, [Text.UTF8Encoding]::new($false))
    try {
        $encodedBaseUrl = & $FqPath -R -s '.' $baseUrlRawPath 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Could not encode ANTHROPIC_BASE_URL.`n$($encodedBaseUrl -join "`n")"
        }
        [IO.File]::WriteAllText($BaseUrlInputPath, (($encodedBaseUrl -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
    }
    finally {
        Remove-Item -LiteralPath $baseUrlRawPath -Force -ErrorAction SilentlyContinue
        $baseUrl = $null
    }
}

function Set-WindowsManagedHook {
    param([string]$SettingsPath)

    $settings = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json
    $matchingHooks = @()

    if ($null -ne $settings.hooks) {
        foreach ($eventProperty in $settings.hooks.PSObject.Properties) {
            foreach ($matcherBlock in @($eventProperty.Value)) {
                foreach ($hook in @($matcherBlock.hooks)) {
                    if (
                        $hook.type -eq 'command' -and
                        $hook.command -is [string] -and
                        $hook.command.Contains('GENKI_HOOK_ID=deny_nested_agent;')
                    ) {
                        $matchingHooks += $hook
                    }
                }
            }
        }
    }

    if ($matchingHooks.Count -ne 1) {
        throw 'Managed Claude settings must contain exactly one GENKI_HOOK_ID=deny_nested_agent hook.'
    }

    $windowsCommand = @'
# GENKI_HOOK_ID=deny_nested_agent;
$inputJson = [Console]::In.ReadToEnd()
$payload = $inputJson | ConvertFrom-Json
if (-not [string]::IsNullOrEmpty([string]$payload.agent_id)) {
    $response = @{
        hookSpecificOutput = @{
            hookEventName = 'PreToolUse'
            permissionDecision = 'deny'
            permissionDecisionReason = 'Nested subagent creation is disabled: a subagent cannot spawn another Agent.'
        }
    }
    [Console]::Out.WriteLine(($response | ConvertTo-Json -Compress -Depth 4))
}
'@

    $managedHook = $matchingHooks[0]
    $managedHook.command = $windowsCommand
    if ($null -eq $managedHook.PSObject.Properties['shell']) {
        $managedHook | Add-Member -NotePropertyName 'shell' -NotePropertyValue 'powershell'
    }
    else {
        $managedHook.shell = 'powershell'
    }

    $serializedSettings = $settings | ConvertTo-Json -Depth 100
    [IO.File]::WriteAllText($SettingsPath, ($serializedSettings + "`n"), [Text.UTF8Encoding]::new($false))
}

$ConfigBaseUrl = (Get-EnvironmentValue 'GENKI_CONFIG_BASE_URL' $RepositoryRawUrl).TrimEnd('/')
$SettingsUrl = Get-EnvironmentValue 'GENKI_CLAUDE_SETTINGS_URL' "$ConfigBaseUrl/claude/settings.json"
$DeleteUrl = Get-EnvironmentValue 'GENKI_CLAUDE_DELETE_URL' "$ConfigBaseUrl/claude/delete.json"
$UserHome = [Environment]::GetFolderPath('UserProfile')
$ClaudeConfigDirectory = Get-EnvironmentValue 'CLAUDE_CONFIG_DIR' (Join-Path $UserHome '.claude')
$SettingsPath = Get-EnvironmentValue 'CLAUDE_SETTINGS_PATH' (Join-Path $ClaudeConfigDirectory 'settings.json')

$TempDir = Join-Path ([IO.Path]::GetTempPath()) ("genki-claude-config-" + [Guid]::NewGuid().ToString('N'))
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

def block_anchor_id:
  [
    .hooks[]?
    | select(.type? == "command")
    | .command?
    | select(type == "string")
    | select(contains("GENKI_HOOK_ID="))
    | if test("GENKI_HOOK_ID=[A-Za-z0-9_-]+;") then
        split("GENKI_HOOK_ID=")[1] | split(";")[0]
      else
        error("invalid GENKI_HOOK_ID marker")
      end
  ] as $ids
  | if ($ids | length) == 0 then
      null
    elif ($ids | length) == 1 then
      $ids[0]
    else
      error("a managed hook matcher block must contain exactly one GENKI_HOOK_ID")
    end;

def managed_hook_blocks:
  (.hooks // {})
  | if type == "object" then . else error("settings.hooks must be an object") end
  | to_entries[]
  | if (.value | type) == "array" then . else error("each hook event must be an array") end
  | .key as $event
  | .value[]
  | . as $block
  | (block_anchor_id) as $id
  | select($id != null)
  | {event: $event, id: $id, block: $block};

def without_managed_hook_blocks:
  . as $settings
  | reduce ((.hooks // {}) | keys[]) as $event (
      $settings;
      (.hooks[$event] | map(select(block_anchor_id == null))) as $regular_blocks
      | if ($regular_blocks | length) == 0 then
          del(.hooks[$event])
        else
          .hooks[$event] = $regular_blocks
        end
    )
  | if .hooks? == {} then del(.hooks) else . end;

def matching_hook_blocks($settings; $id):
  [
    ($settings.hooks // {} | to_entries[]) as $event
    | ($event.value | to_entries[]) as $indexed_block
    | $indexed_block.value.hooks[]?
    | select(.type? == "command")
    | .command?
    | select(type == "string")
    | select(contains("GENKI_HOOK_ID=" + $id + ";"))
    | {event: $event.key, index: $indexed_block.key}
  ];

def append_hook_block($event; $block):
  if .hooks? == null then .hooks = {} else . end
  | if .hooks[$event]? == null then .hooks[$event] = [] else . end
  | .hooks[$event] += [$block];

def remove_hook_block($event; $index):
  delpaths([["hooks", $event, $index]])
  | if (.hooks[$event] | length) == 0 then del(.hooks[$event]) else . end
  | if .hooks == {} then del(.hooks) else . end;

def upsert_managed_hook_blocks($settings; $managed_blocks):
  reduce $managed_blocks[] as $managed (
    $settings;
    (matching_hook_blocks(.; $managed.id)) as $matches
    | if ($matches | length) > 1 then
        error("duplicate GENKI_HOOK_ID=" + $managed.id)
      elif ($matches | length) == 0 then
        append_hook_block($managed.event; $managed.block)
      else
        $matches[0] as $match
        | if $match.event == $managed.event then
            setpath(["hooks", $match.event, $match.index]; $managed.block)
          else
            remove_hook_block($match.event; $match.index)
            | append_hook_block($managed.event; $managed.block)
          end
      end
  );

.[0] as $current
| .[1] as $incoming
| .[3] as $prompted_token
| .[4] as $prompted_base_url
| (
    $incoming
    | if $prompted_token == null then
        delpaths([["env", "ANTHROPIC_AUTH_TOKEN"]])
      else
        setpath(["env", "ANTHROPIC_AUTH_TOKEN"]; $prompted_token)
      end
    | if $prompted_base_url == null then
        delpaths([["env", "ANTHROPIC_BASE_URL"]])
      else
        setpath(["env", "ANTHROPIC_BASE_URL"]; $prompted_base_url)
      end
  ) as $effective_incoming
| ($effective_incoming | [managed_hook_blocks]) as $managed_blocks
| if (($managed_blocks | map(.id) | unique | length) != ($managed_blocks | length)) then
    error("duplicate GENKI_HOOK_ID in managed Claude settings")
  else
    .
  end
| reduce $managed_blocks[] as $managed (
    $current;
    if (matching_hook_blocks($current; $managed.id) | length) > 1 then
      error("duplicate GENKI_HOOK_ID=" + $managed.id + " in current Claude settings")
    else
      .
    end
  ) as $validated_current
| ($effective_incoming | without_managed_hook_blocks) as $regular_incoming
| ($validated_current * $regular_incoming) as $base_merged
| upsert_managed_hook_blocks($base_merged; $managed_blocks) as $merged
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
'@

try {
    $settingsSource = Join-Path $TempDir 'settings.json'
    $deleteSource = Join-Path $TempDir 'delete.json'
    Write-Host 'Downloading managed Claude configuration...'
    Download-File $SettingsUrl $settingsSource
    Download-File $DeleteUrl $deleteSource
    $FqPath = Install-Fq

    $targetDirectory = Split-Path -Parent $SettingsPath
    New-Item -ItemType Directory -Force -Path $targetDirectory | Out-Null

    $current = Join-Path $TempDir 'current.json'
    if (Test-Path -LiteralPath $SettingsPath -PathType Leaf) {
        Copy-Item -LiteralPath $SettingsPath -Destination $current
    }
    else {
        [IO.File]::WriteAllText($current, "{}`n", [Text.UTF8Encoding]::new($false))
    }

    $validationQuery = @'
fromjson
| if type == "object" then
    .
  else
    error("the top-level JSON value must be an object")
  end
'@
    $validationQueryPath = Join-Path $TempDir 'validate-json-object.fq'
    [IO.File]::WriteAllText($validationQueryPath, $validationQuery, [Text.UTF8Encoding]::new($false))

    Assert-ValidJsonObjectFile -FqPath $FqPath -Path $current -Label 'The existing Claude settings file' -QueryPath $validationQueryPath
    Assert-ValidJsonObjectFile -FqPath $FqPath -Path $settingsSource -Label 'The downloaded Claude settings file' -QueryPath $validationQueryPath
    Assert-ValidJsonObjectFile -FqPath $FqPath -Path $deleteSource -Label 'The downloaded Claude deletion file' -QueryPath $validationQueryPath
    Set-WindowsManagedHook -SettingsPath $settingsSource
    Assert-ValidJsonObjectFile -FqPath $FqPath -Path $settingsSource -Label 'The platform-adjusted Claude settings file' -QueryPath $validationQueryPath

    $tokenInput = Join-Path $TempDir 'token.json'
    Write-TokenInput -FqPath $FqPath -CurrentPath $current -TokenInputPath $tokenInput -TemporaryDirectory $TempDir

    $baseUrlInput = Join-Path $TempDir 'base-url.json'
    Write-BaseUrlInput -FqPath $FqPath -CurrentPath $current -BaseUrlInputPath $baseUrlInput -TemporaryDirectory $TempDir

    $fqQueryPath = Join-Path $TempDir 'merge.fq'
    [IO.File]::WriteAllText($fqQueryPath, $FqQuery, [Text.UTF8Encoding]::new($false))
    $mergeOutput = & $FqPath -d json -V -s -f $fqQueryPath $current $settingsSource $deleteSource $tokenInput $baseUrlInput 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Could not merge Claude settings. The existing file was left unchanged.`n$($mergeOutput -join "`n")"
    }

    $ActiveStage = Join-Path $targetDirectory ('.genki-config-' + [Guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText($ActiveStage, (($mergeOutput -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))

    Assert-ValidJsonObjectFile -FqPath $FqPath -Path $ActiveStage -Label 'The merged Claude settings file' -QueryPath $validationQueryPath

    Backup-File
    Move-Item -LiteralPath $ActiveStage -Destination $SettingsPath -Force
    $ActiveStage = $null

    Write-Host "Updated: $SettingsPath"
    Write-Host 'Claude configuration installed successfully. Managed values override matching local values.'
}
finally {
    if ($null -ne $ActiveStage) {
        Remove-Item -LiteralPath $ActiveStage -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $TempDir -Recurse -Force -ErrorAction SilentlyContinue
}
