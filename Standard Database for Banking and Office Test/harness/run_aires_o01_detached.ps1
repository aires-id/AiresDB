$ErrorActionPreference = 'Stop'
$workspace = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$base = Join-Path $workspace 'Standard Database for Banking and Office Test\SDEBO-S750-AiresDB-vs-Firebird-20260909'
$script = Join-Path $PSScriptRoot 'run_aires_o01.jl'
$stdout = Join-Path $base 'resilience\AiresDB\o01-rerun.stdout.log'
$stderr = Join-Path $base 'resilience\AiresDB\o01-rerun.stderr.log'
Set-Location -LiteralPath $workspace
& julia.exe --startup-file=no --project=. --threads=4 $script "--root=$base\resilience\AiresDB\work" "--output=$base\resilience\AiresDB\o01-rerun.json" --duration=900 1> $stdout 2> $stderr
exit $LASTEXITCODE
