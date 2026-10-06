$ErrorActionPreference = "Stop"
dotnet run --project (Join-Path $PSScriptRoot "windows\WindowsRegression.csproj")
if ($LASTEXITCODE -ne 0) { throw "Windows regression checks failed." }
