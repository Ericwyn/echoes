[CmdletBinding()]
param(
    [string]$BundleDirectory,
    [string]$OutputDirectory,
    [string]$IsccPath
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $BundleDirectory) {
    $BundleDirectory = Join-Path $projectRoot 'build/windows/x64/runner/Release'
}
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $projectRoot 'build/windows/packages'
}
$bundlePath = (Resolve-Path -LiteralPath $BundleDirectory).Path
$requiredFiles = @(
    'echoes.exe', 'flutter_windows.dll', 'libmpv-2.dll', 'sqlite3.dll',
    'data/app.so', 'data/icudtl.dat', 'data/flutter_assets/AssetManifest.bin',
    'data/flutter_assets/FontManifest.json', 'data/flutter_assets/assets/tray_icon.ico'
)
foreach ($relativePath in $requiredFiles) {
    $file = Get-Item -LiteralPath (Join-Path $bundlePath $relativePath) -ErrorAction SilentlyContinue
    if (-not $file -or $file.PSIsContainer -or $file.Length -eq 0) {
        throw "Incomplete Windows release bundle: missing $relativePath"
    }
}

$versionLine = Get-Content -LiteralPath (Join-Path $projectRoot 'pubspec.yaml') |
    Where-Object { $_ -match '^version:\s*' } | Select-Object -First 1
if ($versionLine -notmatch '^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$') {
    throw 'Expected pubspec version in major.minor.patch+build format'
}
$appVersion = $Matches[1]
$buildNumber = $Matches[2]
$version = "$appVersion+$buildNumber"
$windowsVersion = "$appVersion.$buildNumber"
$executableVersion = (Get-Item -LiteralPath (Join-Path $bundlePath 'echoes.exe')).VersionInfo.ProductVersion
if ($executableVersion -ne $version) {
    throw "Bundle version $executableVersion does not match pubspec $version; rebuild Windows first"
}

if (-not $IsccPath) {
    $compiler = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($compiler) {
        $IsccPath = $compiler.Source
    } else {
        $IsccPath = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6/ISCC.exe'
    }
}
if (-not (Test-Path -LiteralPath $IsccPath -PathType Leaf)) {
    throw 'Inno Setup compiler not found. Install Inno Setup 6 or specify -IsccPath.'
}

# Use the redistributable CRT from the same Visual Studio installation as CMake.
$vsInstallation = $null
$cmakeCache = Join-Path $projectRoot 'build/windows/x64/CMakeCache.txt'
if (Test-Path -LiteralPath $cmakeCache) {
    $instance = Get-Content -LiteralPath $cmakeCache |
        Where-Object { $_ -match '^CMAKE_GENERATOR_INSTANCE:INTERNAL=' } |
        Select-Object -First 1
    if ($instance) { $vsInstallation = $instance.Split('=', 2)[1] }
}
if (-not $vsInstallation) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    if (Test-Path -LiteralPath $vswhere) {
        $vsInstallation = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    }
}
if (-not $vsInstallation) { throw 'Visual Studio C++ redistributable location not found' }
$redistVersions = Get-ChildItem -LiteralPath (Join-Path $vsInstallation 'VC/Redist/MSVC') -Directory |
    Where-Object { $_.Name -match '^\d+(\.\d+)+$' } |
    Sort-Object { [version]$_.Name } -Descending
$crtDirectory = $null
foreach ($redistVersion in $redistVersions) {
    $crtDirectory = Get-ChildItem -LiteralPath (Join-Path $redistVersion.FullName 'x64') -Directory |
        Where-Object { $_.Name -match '^Microsoft\.VC\d+\.CRT$' } |
        Select-Object -First 1
    if ($crtDirectory) { break }
}
if (-not $crtDirectory) { throw 'Visual C++ x64 redistributable CRT not found' }

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$outputPath = (Resolve-Path -LiteralPath $OutputDirectory).Path
$packageBaseName = "echoes-$version-windows-x64"
$stagingRoot = Join-Path $outputPath ('.staging-' + [guid]::NewGuid().ToString('N'))
$stagedBundle = Join-Path $stagingRoot $packageBaseName
New-Item -ItemType Directory -Path $stagedBundle -Force | Out-Null
try {
    Copy-Item -Path (Join-Path $bundlePath '*') -Destination $stagedBundle -Recurse -Exclude '*.lib', '*.exp', '*.pdb'
    Copy-Item -Path (Join-Path $crtDirectory.FullName '*.dll') -Destination $stagedBundle -Force
    foreach ($runtimeFile in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
        if (-not (Test-Path -LiteralPath (Join-Path $stagedBundle $runtimeFile) -PathType Leaf)) {
            throw "Missing packaged Visual C++ runtime: $runtimeFile"
        }
    }

    $compilerArguments = @(
        '/Qp', "/DAppVersion=$version", "/DWindowsVersion=$windowsVersion",
        "/DPackageOutputDir=$outputPath", "/DPackageBaseName=$packageBaseName",
        "/DBundleDir=$stagedBundle", "/DAppIcon=$(Join-Path $projectRoot 'assets/tray_icon.ico')",
        (Join-Path $projectRoot 'packaging/windows/echoes.iss')
    )
    & $IsccPath @compilerArguments
    if ($LASTEXITCODE -ne 0) { throw "Inno Setup compilation failed: $LASTEXITCODE" }

    $installerPath = Join-Path $outputPath "$packageBaseName-setup.exe"
    $zipPath = Join-Path $outputPath "$packageBaseName-portable.zip"
    Compress-Archive -LiteralPath $stagedBundle -DestinationPath $zipPath -CompressionLevel Optimal -Force
    $checksums = foreach ($artifact in @($installerPath, $zipPath)) {
        $file = Get-Item -LiteralPath $artifact
        if ($file.Length -eq 0) { throw "Empty package: $artifact" }
        $hash = Get-FileHash -LiteralPath $artifact -Algorithm SHA256
        "$($hash.Hash.ToLowerInvariant())  $($file.Name)"
    }
    $checksums | Set-Content -LiteralPath (Join-Path $outputPath "$packageBaseName-SHA256SUMS.txt") -Encoding ascii
    Write-Output "Windows installer: $installerPath"
    Write-Output "Portable ZIP: $zipPath"
} finally {
    # Only remove the unique staging folder inside the resolved package directory.
    $resolvedStaging = (Resolve-Path -LiteralPath $stagingRoot).Path
    if ((Split-Path -Parent $resolvedStaging) -ne $outputPath -or
        (Split-Path -Leaf $resolvedStaging) -notmatch '^\.staging-[a-f0-9]{32}$') {
        throw "Refusing to clean unexpected staging path: $resolvedStaging"
    }
    Remove-Item -LiteralPath $resolvedStaging -Recurse -Force
}
