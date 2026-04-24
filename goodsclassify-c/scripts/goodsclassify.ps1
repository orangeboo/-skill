param(
    [Parameter(Mandatory = $true)]
    [string]$Message,

    [string]$SessionId = 'default'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

function Decode-Base64Utf8 {
    param([string]$Value)

    return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Value))
}

function Get-Text {
    param([string]$Name)

    switch ($Name) {
        'ask_phone' { return Decode-Base64Utf8 '6K+35YWI6L6T5YWl5omL5py65Y+377yI5LuF6aaW5qyh6ZyA6KaB77yJ' }
        'phone_saved' { return Decode-Base64Utf8 '5omL5py65Y+35bey5L+d5a2Y77yM6K+357un57ut6L6T5YWl5ZWG5ZOB5b2S57G76Zeu6aKY44CC' }
        'phone_updated' { return Decode-Base64Utf8 '5omL5py65Y+35bey5pu05paw77yM6K+357un57ut6L6T5YWl5ZWG5ZOB5b2S57G76Zeu6aKY44CC' }
        default { throw "Unknown text key: $Name" }
    }
}

function Get-SkillRoot {
    return (Split-Path -Parent $PSScriptRoot)
}

function Get-SafeSessionId {
    param([string]$RawSessionId)

    if ([string]::IsNullOrWhiteSpace($RawSessionId)) {
        return 'default'
    }

    return (($RawSessionId.Trim()) -replace '[\\/:*?"<>|]', '_')
}

function New-RequestChatId {
    param(
        [string]$CurrentSessionId,
        [string]$AgentName
    )

    $timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $suffix = [guid]::NewGuid().Guid
    return ($CurrentSessionId + '-' + $AgentName + '-' + $timestamp + '-' + $suffix)
}

function Read-DotEnv {
    param([string]$Path)

    $result = @{}
    if (-not (Test-Path -LiteralPath $Path)) {
        return $result
    }

    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        $current = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($current)) { continue }
        if ($current.StartsWith('#')) { continue }

        $parts = $current -split '=', 2
        if ($parts.Count -ne 2) { continue }

        $key = $parts[0].Trim()
        $value = $parts[1].Trim()
        if ($value.StartsWith('"') -and $value.EndsWith('"')) {
            $value = $value.Substring(1, $value.Length - 2)
        }

        $result[$key] = $value
    }

    return $result
}

function Get-ConfigValue {
    param(
        [hashtable]$DotEnv,
        [string]$Key,
        [string]$DefaultValue = ''
    )

    $envValue = [Environment]::GetEnvironmentVariable($Key)
    if (-not [string]::IsNullOrWhiteSpace($envValue)) {
        return $envValue.Trim()
    }

    if ($DotEnv.ContainsKey($Key) -and -not [string]::IsNullOrWhiteSpace($DotEnv[$Key])) {
        return ([string]$DotEnv[$Key]).Trim()
    }

    return $DefaultValue
}

function Ensure-DataDir {
    param([string]$Root)

    $dir = Join-Path $Root 'data'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    return $dir
}

function Get-StatePaths {
    param(
        [string]$Root,
        [string]$RawSessionId
    )

    $session = Get-SafeSessionId -RawSessionId $RawSessionId
    $dataDir = Ensure-DataDir -Root $Root

    return @{
        PhoneFile = (Join-Path $dataDir ($session + '.phone.txt'))
        PendingFile = (Join-Path $dataDir ($session + '.pending.txt'))
        AwaitPhoneFile = (Join-Path $dataDir ($session + '.await-phone.txt'))
    }
}

function Get-NowUnixMs {
    return [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
}

function Read-TextFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ($null -eq $content) {
        return $null
    }

    $trimmed = $content.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return $null
    }

    return $trimmed
}

function Write-TextFile {
    param(
        [string]$Path,
        [string]$Content
    )

    Set-Content -LiteralPath $Path -Value $Content -Encoding UTF8 -NoNewline
}

function Write-PlainText {
    param(
        [string]$Text,
        [switch]$NoNewline
    )

    if ($NoNewline) {
        [Console]::Write($Text)
    }
    else {
        [Console]::WriteLine($Text)
    }

    [Console]::Out.Flush()
}

function Remove-TextFile {
    param([string]$Path)

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Force
    }
}

function Test-IsPhoneNumber {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    return ($Value.Trim() -match '^1[3-9]\d{9}$')
}

function Normalize-Bearer {
    param([string]$Token)

    $trimmed = $Token.Trim()
    if ($trimmed -match '^(?i)bearer\s+') {
        return $trimmed
    }

    return ('Bearer ' + $trimmed)
}

function Convert-ToJsonString {
    param($Value)

    return ($Value | ConvertTo-Json -Depth 20 -Compress)
}

function Get-ResponseContent {
    param($Response)

    if ($Response -is [string]) {
        return $Response.Trim()
    }

    if ($null -ne $Response.PSObject.Properties['choices'] -and $Response.choices.Count -gt 0) {
        $choice = $Response.choices[0]
        if ($null -ne $choice.message -and $null -ne $choice.message.content) {
            return ([string]$choice.message.content).Trim()
        }
    }

    foreach ($name in @('text', 'content', 'data', 'message')) {
        if ($null -ne $Response.PSObject.Properties[$name]) {
            $value = $Response.$name
            if ($value -is [string] -and -not [string]::IsNullOrWhiteSpace($value)) {
                return $value.Trim()
            }
        }
    }

    return (Convert-ToJsonString -Value $Response)
}

function Get-ChunkContent {
    param($Response)

    if ($Response -is [string]) {
        return $Response
    }

    if ($null -ne $Response.PSObject.Properties['choices'] -and $Response.choices.Count -gt 0) {
        $choice = $Response.choices[0]

        if ($null -ne $choice.PSObject.Properties['delta'] -and $null -ne $choice.delta) {
            if ($null -ne $choice.delta.PSObject.Properties['content'] -and $null -ne $choice.delta.content) {
                return [string]$choice.delta.content
            }
        }

        if ($null -ne $choice.PSObject.Properties['message'] -and $null -ne $choice.message) {
            if ($null -ne $choice.message.PSObject.Properties['content'] -and $null -ne $choice.message.content) {
                return [string]$choice.message.content
            }
        }
    }

    foreach ($name in @('text', 'content')) {
        if ($null -ne $Response.PSObject.Properties[$name] -and $Response.$name) {
            return [string]$Response.$name
        }
    }

    return ''
}

function Try-ParseJson {
    param([string]$Text)

    try {
        return ($Text | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Invoke-Agent {
    param(
        [string]$ApiUrl,
        [string]$ApiKey,
        [string]$Content,
        [string]$ChatId,
        [hashtable]$Variables = @{},
        [int]$TimeoutSec = 60
    )

    if ([string]::IsNullOrWhiteSpace($Content)) {
        throw 'Request content cannot be empty.'
    }

    $headers = @{
        Authorization = (Normalize-Bearer -Token $ApiKey)
        'Content-Type' = 'application/json'
    }

    $payload = @{
        chatId = $ChatId
        stream = $false
        detail = $false
        responseChatItemId = [guid]::NewGuid().Guid
        variables = $Variables
        messages = @(
            @{
                role = 'user'
                content = $Content
            }
        )
    }

    $body = Convert-ToJsonString -Value $payload

    try {
        $response = Invoke-RestMethod -Method Post -Uri $ApiUrl -Headers $headers -Body $body -TimeoutSec $TimeoutSec
    }
    catch {
        throw ('FastGPT request failed: ' + $_.Exception.Message)
    }

    return (Get-ResponseContent -Response $response)
}

function Invoke-AgentStream {
    param(
        [string]$ApiUrl,
        [string]$ApiKey,
        [string]$Content,
        [string]$ChatId,
        [hashtable]$Variables = @{},
        [int]$TimeoutSec = 60
    )

    if ([string]::IsNullOrWhiteSpace($Content)) {
        throw 'Request content cannot be empty.'
    }

    $payload = @{
        chatId = $ChatId
        stream = $true
        detail = $false
        responseChatItemId = [guid]::NewGuid().Guid
        variables = $Variables
        messages = @(
            @{
                role = 'user'
                content = $Content
            }
        )
    }

    $body = Convert-ToJsonString -Value $payload
    $request = [System.Net.HttpWebRequest]::Create($ApiUrl)
    $request.Method = 'POST'
    $request.ContentType = 'application/json'
    $request.Accept = 'text/event-stream'
    $request.Timeout = $TimeoutSec * 1000
    $request.ReadWriteTimeout = $TimeoutSec * 1000
    $request.Headers['Authorization'] = (Normalize-Bearer -Token $ApiKey)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    $request.ContentLength = $bytes.Length

    $requestStream = $null
    $response = $null
    $responseStream = $null
    $reader = $null
    $builder = New-Object System.Text.StringBuilder

    try {
        $requestStream = $request.GetRequestStream()
        $requestStream.Write($bytes, 0, $bytes.Length)
        $requestStream.Flush()
        $requestStream.Close()
        $requestStream = $null

        $response = $request.GetResponse()
        $responseStream = $response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($responseStream, [System.Text.Encoding]::UTF8)

        while (($line = $reader.ReadLine()) -ne $null) {
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }

            if (-not $line.StartsWith('data:')) {
                continue
            }

            $data = $line.Substring(5).Trim()
            if ([string]::IsNullOrWhiteSpace($data)) {
                continue
            }

            if ($data -eq '[DONE]') {
                break
            }

            $event = Try-ParseJson -Text $data
            if ($null -eq $event) {
                continue
            }

            $chunk = Get-ChunkContent -Response $event
            if (-not [string]::IsNullOrEmpty($chunk)) {
                [void]$builder.Append($chunk)
                Write-PlainText -Text $chunk -NoNewline
            }
        }
    }
    catch {
        throw ('FastGPT stream request failed: ' + $_.Exception.Message)
    }
    finally {
        if ($null -ne $reader) { $reader.Close() }
        if ($null -ne $responseStream) { $responseStream.Close() }
        if ($null -ne $response) { $response.Close() }
        if ($null -ne $requestStream) { $requestStream.Close() }
    }

    Write-PlainText -Text ''
    return $builder.ToString()
}

function Test-RemotePhoneExists {
    param(
        [string]$ApiUrl,
        [string]$ApiKey,
        [string]$Phone,
        [string]$CurrentSessionId,
        [int]$TimeoutSec
    )

    if ([string]::IsNullOrWhiteSpace($Phone)) {
        throw 'Phone cannot be empty.'
    }

    $chatId = New-RequestChatId -CurrentSessionId $CurrentSessionId -AgentName 'agent-a'
    $raw = Invoke-Agent -ApiUrl $ApiUrl -ApiKey $ApiKey -Content $Phone -ChatId $chatId -TimeoutSec $TimeoutSec
    $parsed = Try-ParseJson -Text $raw

    if ($parsed -is [System.Array]) {
        return ($parsed.Count -gt 0)
    }

    if ($null -ne $parsed) {
        if ($null -ne $parsed.PSObject.Properties['exists']) {
            return [bool]$parsed.exists
        }

        if ($null -ne $parsed.PSObject.Properties['data']) {
            $dataValue = $parsed.data
            if ($dataValue -is [System.Array]) {
                return ($dataValue.Count -gt 0)
            }
        }
    }

    $normalized = $raw.Trim().ToLowerInvariant()
    if ($normalized -eq '[]') {
        return $false
    }

    if ($normalized.Contains('"guest_id"')) {
        return $true
    }

    if ($normalized -eq '{}') {
        return $false
    }

    if ($normalized.Contains('"exists":true')) {
        return $true
    }

    if ($normalized.Contains('"exists":false')) {
        return $false
    }

    return $false
}

function Register-RemotePhone {
    param(
        [string]$ApiUrl,
        [string]$ApiKey,
        [string]$Phone,
        [string]$CurrentSessionId,
        [int]$TimeoutSec
    )

    $chatId = New-RequestChatId -CurrentSessionId $CurrentSessionId -AgentName 'agent-b'
    $raw = Invoke-Agent -ApiUrl $ApiUrl -ApiKey $ApiKey -Content $Phone -ChatId $chatId -TimeoutSec $TimeoutSec
    $parsed = Try-ParseJson -Text $raw

    if ($null -ne $parsed) {
        if ($null -ne $parsed.PSObject.Properties['affectedRows'] -and [int]$parsed.affectedRows -ge 1) {
            return $true
        }

        if ($null -ne $parsed.PSObject.Properties['changedRows'] -and [int]$parsed.changedRows -ge 1) {
            return $true
        }
    }

    $normalized = $raw.Trim().ToLowerInvariant()
    return $normalized.Contains('success')
}

function Invoke-ClassifierStream {
    param(
        [string]$ApiUrl,
        [string]$ApiKey,
        [string]$Question,
        [string]$CurrentSessionId,
        [string]$Phone,
        [int]$TimeoutSec
    )

    $chatId = New-RequestChatId -CurrentSessionId $CurrentSessionId -AgentName 'agent-c'
    $variables = @{
        phone = $Phone
        session_id = $CurrentSessionId
    }

    try {
        [void](Invoke-AgentStream -ApiUrl $ApiUrl -ApiKey $ApiKey -Content $Question -ChatId $chatId -Variables $variables -TimeoutSec $TimeoutSec)
    }
    catch {
        $fallback = Invoke-Agent -ApiUrl $ApiUrl -ApiKey $ApiKey -Content $Question -ChatId $chatId -Variables $variables -TimeoutSec $TimeoutSec
        Write-PlainText -Text $fallback
    }
}

$skillRoot = Get-SkillRoot
$dotEnv = Read-DotEnv -Path (Join-Path $skillRoot '.env')

$apiUrl = Get-ConfigValue -DotEnv $dotEnv -Key 'FASTGPT_API_URL'
$agentAKey = Get-ConfigValue -DotEnv $dotEnv -Key 'AGENT_A_KEY'
$agentBKey = Get-ConfigValue -DotEnv $dotEnv -Key 'AGENT_B_KEY'
$agentCKey = Get-ConfigValue -DotEnv $dotEnv -Key 'AGENT_C_KEY'
$timeoutSec = [int](Get-ConfigValue -DotEnv $dotEnv -Key 'FASTGPT_TIMEOUT' -DefaultValue '200')
$minPhoneReplyDelayMs = [int](Get-ConfigValue -DotEnv $dotEnv -Key 'MIN_PHONE_REPLY_DELAY_MS' -DefaultValue '4000')

if ([string]::IsNullOrWhiteSpace($apiUrl)) { throw 'Missing FASTGPT_API_URL.' }
if ([string]::IsNullOrWhiteSpace($agentAKey)) { throw 'Missing AGENT_A_KEY.' }
if ([string]::IsNullOrWhiteSpace($agentBKey)) { throw 'Missing AGENT_B_KEY.' }
if ([string]::IsNullOrWhiteSpace($agentCKey)) { throw 'Missing AGENT_C_KEY.' }

$cleanMessage = $Message.Trim()
if ([string]::IsNullOrWhiteSpace($cleanMessage)) {
    throw 'Message cannot be empty.'
}

$state = Get-StatePaths -Root $skillRoot -RawSessionId $SessionId
$phoneFile = $state['PhoneFile']
$pendingFile = $state['PendingFile']
$awaitPhoneFile = $state['AwaitPhoneFile']
$savedPhone = Read-TextFile -Path $phoneFile

if (-not $savedPhone) {
    if (-not (Test-IsPhoneNumber -Value $cleanMessage)) {
        Write-TextFile -Path $pendingFile -Content $cleanMessage
        Write-TextFile -Path $awaitPhoneFile -Content ([string](Get-NowUnixMs))
        Write-PlainText -Text (Get-Text -Name 'ask_phone')
        exit 0
    }

    $awaitPhoneAt = Read-TextFile -Path $awaitPhoneFile
    if ([string]::IsNullOrWhiteSpace($awaitPhoneAt)) {
        Write-TextFile -Path $awaitPhoneFile -Content ([string](Get-NowUnixMs))
        Write-PlainText -Text (Get-Text -Name 'ask_phone')
        exit 0
    }

    $elapsedMs = (Get-NowUnixMs) - [long]$awaitPhoneAt
    if ($elapsedMs -lt $minPhoneReplyDelayMs) {
        Write-PlainText -Text (Get-Text -Name 'ask_phone')
        exit 0
    }

    $exists = Test-RemotePhoneExists -ApiUrl $apiUrl -ApiKey $agentAKey -Phone $cleanMessage -CurrentSessionId $SessionId -TimeoutSec $timeoutSec
    if (-not $exists) {
        $registered = Register-RemotePhone -ApiUrl $apiUrl -ApiKey $agentBKey -Phone $cleanMessage -CurrentSessionId $SessionId -TimeoutSec $timeoutSec
        if (-not $registered) {
            throw 'Failed to register phone.'
        }
    }

    Write-TextFile -Path $phoneFile -Content $cleanMessage
    Remove-TextFile -Path $awaitPhoneFile

    $pendingQuestion = Read-TextFile -Path $pendingFile
    if ($pendingQuestion) {
        Remove-TextFile -Path $pendingFile
        Invoke-ClassifierStream -ApiUrl $apiUrl -ApiKey $agentCKey -Question $pendingQuestion -CurrentSessionId $SessionId -Phone $cleanMessage -TimeoutSec $timeoutSec
        exit 0
    }

    Write-PlainText -Text (Get-Text -Name 'phone_saved')
    exit 0
}

if (Test-IsPhoneNumber -Value $cleanMessage) {
    $awaitPhoneAt = Read-TextFile -Path $awaitPhoneFile
    if ([string]::IsNullOrWhiteSpace($awaitPhoneAt)) {
        Write-TextFile -Path $awaitPhoneFile -Content ([string](Get-NowUnixMs))
        Write-PlainText -Text (Get-Text -Name 'ask_phone')
        exit 0
    }

    $elapsedMs = (Get-NowUnixMs) - [long]$awaitPhoneAt
    if ($elapsedMs -lt $minPhoneReplyDelayMs) {
        Write-PlainText -Text (Get-Text -Name 'ask_phone')
        exit 0
    }

    $exists = Test-RemotePhoneExists -ApiUrl $apiUrl -ApiKey $agentAKey -Phone $cleanMessage -CurrentSessionId $SessionId -TimeoutSec $timeoutSec
    if (-not $exists) {
        $registered = Register-RemotePhone -ApiUrl $apiUrl -ApiKey $agentBKey -Phone $cleanMessage -CurrentSessionId $SessionId -TimeoutSec $timeoutSec
        if (-not $registered) {
            throw 'Failed to register phone.'
        }
    }

    Write-TextFile -Path $phoneFile -Content $cleanMessage
    Remove-TextFile -Path $awaitPhoneFile

    $pendingQuestion = Read-TextFile -Path $pendingFile
    if ($pendingQuestion) {
        Remove-TextFile -Path $pendingFile
        Invoke-ClassifierStream -ApiUrl $apiUrl -ApiKey $agentCKey -Question $pendingQuestion -CurrentSessionId $SessionId -Phone $cleanMessage -TimeoutSec $timeoutSec
        exit 0
    }

    Write-PlainText -Text (Get-Text -Name 'phone_updated')
    exit 0
}

$exists = Test-RemotePhoneExists -ApiUrl $apiUrl -ApiKey $agentAKey -Phone $savedPhone -CurrentSessionId $SessionId -TimeoutSec $timeoutSec
if (-not $exists) {
    $registered = Register-RemotePhone -ApiUrl $apiUrl -ApiKey $agentBKey -Phone $savedPhone -CurrentSessionId $SessionId -TimeoutSec $timeoutSec
    if (-not $registered) {
        throw 'Failed to register phone.'
    }
}

Invoke-ClassifierStream -ApiUrl $apiUrl -ApiKey $agentCKey -Question $cleanMessage -CurrentSessionId $SessionId -Phone $savedPhone -TimeoutSec $timeoutSec
