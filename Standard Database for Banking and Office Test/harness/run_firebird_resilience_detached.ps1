$ErrorActionPreference = 'Stop'
$workspace = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$base = Join-Path $workspace 'Standard Database for Banking and Office Test\SDEBO-S750-AiresDB-vs-Firebird-20260909'
$python = 'C:\Users\aires\AppData\Local\Temp\sdbeo-python\Scripts\python.exe'
$firebird = 'C:\Users\aires\AppData\Local\Temp\sdbeo-firebird-5.0.4-run-20260911'
$script = Join-Path $PSScriptRoot 'run_firebird_resilience.py'
$stdout = Join-Path $base 'resilience\Firebird.stdout.log'
$stderr = Join-Path $base 'resilience\Firebird.stderr.log'
Set-Location -LiteralPath $workspace
& $python $script --source (Join-Path $base 'runs\Firebird\run-1\SDBEO.FDB') --output (Join-Path $base 'resilience\Firebird') --firebird-root $firebird --duration 900 1> $stdout 2> $stderr
exit $LASTEXITCODE
