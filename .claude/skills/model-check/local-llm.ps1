param(
    [Parameter(Mandatory = $false, Position = 0)]
    [string]$Prompt,

    [string]$File,

    [string]$Model = "gpt-oss:20b",

    [double]$Temperature = 0.7
)

if ($File) {
    if (-not (Test-Path $File)) {
        Write-Error "File not found: $File"
        exit 1
    }
    $Prompt = Get-Content -Raw -Path $File
}

if (-not $Prompt -and [Console]::IsInputRedirected) {
    $Prompt = [Console]::In.ReadToEnd()
}

if (-not $Prompt -or $Prompt.Trim() -eq "") {
    Write-Error "No prompt provided. Pass as an argument, -File <path>, or pipe text in."
    exit 1
}

$body = @{
    model  = $Model
    prompt = $Prompt
    stream = $false
    options = @{ temperature = $Temperature }
} | ConvertTo-Json -Depth 5

try {
    $response = Invoke-RestMethod -Uri "http://localhost:11434/api/generate" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 300
}
catch {
    if ($_.Exception.Response) {
        $statusCode = $_.Exception.Response.StatusCode.value__
        $detail = $_.ErrorDetails.Message
        Write-Error "Ollama returned HTTP $statusCode instead of a successful response.$(if ($detail) { " $detail" }) If this is a first run, check the model is pulled (e.g. 'ollama pull $Model')."
    }
    else {
        Write-Error "Could not reach local Ollama server at localhost:11434. Is it running? ($($_.Exception.Message))"
    }
    exit 1
}

$response.response
