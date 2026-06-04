# --- User Configuration ---
# Paste your Groq API Key here
$HardcodedApiKey = "PASTE_YOUR_KEY_HERE"

# --- Orchestration Logic ---
if ($HardcodedApiKey -and $HardcodedApiKey -ne "PASTE_YOUR_KEY_HERE") {
    $env:GROQ_API_KEY = $HardcodedApiKey
}

if (-not $env:GROQ_API_KEY) {
    Write-Host "Error: GROQ_API_KEY is not set." -ForegroundColor Red
    Write-Host "Please edit start_comedy.ps1 and paste your key at the top."
    exit 1
}

Write-Host "=== Launching AI Comedy Show ===" -ForegroundColor Cyan
python orchestrator.py
