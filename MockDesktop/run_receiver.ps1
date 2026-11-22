param(
    [string]$Config = "$PSScriptRoot\config.toml"
)

$localPython = Join-Path $PSScriptRoot "venv\Scripts\python.exe"
$parentPython = Join-Path $PSScriptRoot "..\venv\Scripts\python.exe"
$pythonExecutable = if (Test-Path -LiteralPath $localPython) {
    $localPython
} elseif (Test-Path -LiteralPath $parentPython) {
    $parentPython
} else {
    throw "Ambiente virtual nao encontrado em MockDesktop\venv ou na pasta pai."
}

Push-Location $PSScriptRoot
try {
    & $pythonExecutable -m tools.reference_receiver --config $Config
    exit $LASTEXITCODE
} finally {
    Pop-Location
}
