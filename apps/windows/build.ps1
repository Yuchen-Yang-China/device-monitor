param(
    [switch] $Publish,
    [string] $PublishDirectory = 'artifacts/win-x64'
)

$ErrorActionPreference = 'Stop'
$dotnetCommand = Get-Command dotnet -ErrorAction SilentlyContinue
$dotnetExecutable = if ($dotnetCommand) { $dotnetCommand.Source } else { Join-Path $env:ProgramFiles 'dotnet\dotnet.exe' }
if (-not (Test-Path -LiteralPath $dotnetExecutable)) { throw '.NET SDK 10 is required.' }

& $dotnetExecutable restore DeviceMonitor.slnx
if ($LASTEXITCODE -ne 0) { throw 'dotnet restore failed' }

& $dotnetExecutable build DeviceMonitor.slnx --configuration Release --no-restore
if ($LASTEXITCODE -ne 0) { throw 'dotnet build failed' }

& $dotnetExecutable test tests/DeviceMonitor.Tests/DeviceMonitor.Tests.csproj --configuration Release --no-build --logger 'console;verbosity=minimal'
if ($LASTEXITCODE -ne 0) { throw 'dotnet test failed' }

if ($Publish) {
    $resolvedPublishDirectory = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot $PublishDirectory))
    & $dotnetExecutable publish src/DeviceMonitor.App/DeviceMonitor.App.csproj --configuration Release --runtime win-x64 --self-contained true --output $resolvedPublishDirectory
    if ($LASTEXITCODE -ne 0) { throw 'dotnet publish failed' }

    & $dotnetExecutable build installer/DeviceMonitor.Setup/DeviceMonitor.Setup.wixproj --configuration Release --no-incremental -p:PublishDirectory=$resolvedPublishDirectory
    if ($LASTEXITCODE -ne 0) { throw 'installer build failed' }
}
