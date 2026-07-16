[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet(
    'macos-arm64',
    'macos-x64',
    'ios-arm64',
    'ios-simulator-arm64',
    'ios-simulator-x64',
    'android-arm64',
    'android-armeabi-v7a',
    'android-x86_64',
    'windows-x64'
  )]
  [string] $Target,

  [Parameter(Mandatory = $true)]
  [string] $OutputDirectory,

  [string] $ArchivePath,

  [switch] $RunHostTests
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Invoke-CMake {
  param([string[]] $CommandArguments)

  & cmake @CommandArguments
  if ($LASTEXITCODE -ne 0) {
    throw "cmake failed with exit code ${LASTEXITCODE}: $($CommandArguments -join ' ')"
  }
}

$repository = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
if (-not [IO.Path]::IsPathRooted($OutputDirectory)) {
  $OutputDirectory = Join-Path $repository $OutputDirectory
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if ($ArchivePath -and -not [IO.Path]::IsPathRooted($ArchivePath)) {
  $ArchivePath = Join-Path $repository $ArchivePath
}
if ($ArchivePath) {
  $ArchivePath = [IO.Path]::GetFullPath($ArchivePath)
}

$vtkVersion = '9.5.2'
$vtkDirectory = Join-Path $repository ".dart_tool/vtk/$vtkVersion/$Target/install/lib/cmake/vtk-9.5"
if (-not (Test-Path $vtkDirectory)) {
  throw "Missing bootstrapped VTK for $Target at $vtkDirectory."
}

$buildDirectory = Join-Path $OutputDirectory 'build'
$installDirectory = Join-Path $OutputDirectory 'install'
Remove-Item $OutputDirectory -Recurse -Force -ErrorAction SilentlyContinue
New-Item $OutputDirectory -ItemType Directory -Force | Out-Null

$configureArguments = @(
  '-S', (Join-Path $repository 'native'),
  '-B', $buildDirectory,
  '-DCMAKE_BUILD_TYPE=Release',
  "-DCMAKE_INSTALL_PREFIX=$installDirectory",
  "-DVTK_DIR=$vtkDirectory",
  '-DVTK_FLUTTER_BUILD_SHARED_CORE=ON',
  '-DBUILD_TESTING=OFF'
)

switch ($Target) {
  'macos-arm64' {
    $configureArguments += '-DCMAKE_OSX_ARCHITECTURES=arm64', '-DCMAKE_OSX_DEPLOYMENT_TARGET=11.0'
  }
  'macos-x64' {
    $configureArguments += '-DCMAKE_OSX_ARCHITECTURES=x86_64', '-DCMAKE_OSX_DEPLOYMENT_TARGET=11.0'
  }
  'ios-arm64' {
    $configureArguments += @(
      '-DCMAKE_SYSTEM_NAME=iOS',
      '-DAPPLE_IOS=ON',
      '-DTARGET_OS_IPHONE=ON',
      '-DCMAKE_OSX_ARCHITECTURES=arm64',
      '-DCMAKE_OSX_SYSROOT=iphoneos',
      '-DCMAKE_OSX_DEPLOYMENT_TARGET=13.0'
    )
  }
  'ios-simulator-arm64' {
    $configureArguments += @(
      '-DCMAKE_SYSTEM_NAME=iOS',
      '-DAPPLE_IOS=ON',
      '-DTARGET_IPHONE_SIMULATOR=ON',
      '-DCMAKE_OSX_ARCHITECTURES=arm64',
      '-DCMAKE_OSX_SYSROOT=iphonesimulator',
      '-DCMAKE_OSX_DEPLOYMENT_TARGET=13.0'
    )
  }
  'ios-simulator-x64' {
    $configureArguments += @(
      '-DCMAKE_SYSTEM_NAME=iOS',
      '-DAPPLE_IOS=ON',
      '-DTARGET_IPHONE_SIMULATOR=ON',
      '-DCMAKE_OSX_ARCHITECTURES=x86_64',
      '-DCMAKE_OSX_SYSROOT=iphonesimulator',
      '-DCMAKE_OSX_DEPLOYMENT_TARGET=13.0'
    )
  }
  { $_ -in 'android-arm64', 'android-armeabi-v7a', 'android-x86_64' } {
    $ndkDirectory = $env:ANDROID_NDK_HOME
    if (-not $ndkDirectory) { $ndkDirectory = $env:ANDROID_NDK_ROOT }
    if (-not $ndkDirectory) {
      throw 'ANDROID_NDK_HOME or ANDROID_NDK_ROOT is required for Android builds.'
    }
    $androidAbi = switch ($Target) {
      'android-arm64' { 'arm64-v8a' }
      'android-armeabi-v7a' { 'armeabi-v7a' }
      'android-x86_64' { 'x86_64' }
    }
    $configureArguments += @(
      "-DCMAKE_TOOLCHAIN_FILE=$(Join-Path $ndkDirectory 'build/cmake/android.toolchain.cmake')",
      "-DANDROID_ABI=$androidAbi",
      '-DANDROID_PLATFORM=android-27',
      '-DANDROID_STL=c++_static'
    )
  }
  'windows-x64' {
    $configureArguments += '-A', 'x64'
  }
}

Push-Location $repository
try {
  Invoke-CMake -CommandArguments $configureArguments
  Invoke-CMake -CommandArguments @('--build', $buildDirectory, '--config', 'Release', '--parallel')
  Invoke-CMake -CommandArguments @('--install', $buildDirectory, '--config', 'Release')

  if ($RunHostTests) {
    if ($Target -notin 'macos-arm64', 'macos-x64', 'windows-x64') {
      throw "Host tests cannot run for cross-compiled target $Target."
    }
    $testDirectory = Join-Path $OutputDirectory 'test-build'
    $testArguments = @(
      '-S', (Join-Path $repository 'native'),
      '-B', $testDirectory,
      '-DCMAKE_BUILD_TYPE=Release',
      "-DVTK_DIR=$vtkDirectory",
      '-DVTK_FLUTTER_BUILD_SHARED_CORE=ON',
      '-DBUILD_TESTING=ON'
    )
    if ($Target -eq 'macos-arm64') {
      $testArguments += '-DCMAKE_OSX_ARCHITECTURES=arm64', '-DCMAKE_OSX_DEPLOYMENT_TARGET=11.0'
    } elseif ($Target -eq 'macos-x64') {
      $testArguments += '-DCMAKE_OSX_ARCHITECTURES=x86_64', '-DCMAKE_OSX_DEPLOYMENT_TARGET=11.0'
    } else {
      $testArguments += '-A', 'x64'
    }
    Invoke-CMake -CommandArguments $testArguments
    Invoke-CMake -CommandArguments @('--build', $testDirectory, '--config', 'Release', '--parallel')
    & ctest --test-dir $testDirectory -C Release --output-on-failure
    if ($LASTEXITCODE -ne 0) {
      throw "Native contract tests failed with exit code $LASTEXITCODE."
    }
  }
} finally {
  Pop-Location
}

$libraryName = switch -Wildcard ($Target) {
  'macos-*' { 'libvtk_flutter_core.dylib' }
  'ios-*' { 'libvtk_flutter_core.dylib' }
  'android-*' { 'libvtk_flutter_core.so' }
  'windows-*' { 'vtk_flutter_core.dll' }
}
$libraries = @(Get-ChildItem $installDirectory -Recurse -File -Filter $libraryName)
if ($libraries.Count -ne 1) {
  throw "Expected exactly one $libraryName beneath $installDirectory; found $($libraries.Count)."
}

if ($ArchivePath) {
  New-Item (Split-Path $ArchivePath -Parent) -ItemType Directory -Force | Out-Null
  $stage = Join-Path $OutputDirectory 'archive'
  Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
  New-Item $stage -ItemType Directory -Force | Out-Null
  Copy-Item $libraries[0].FullName (Join-Path $stage $libraryName)

  Push-Location $stage
  try {
    Invoke-CMake -CommandArguments @('-E', 'tar', 'cf', $ArchivePath, '--format=zip', $libraryName)
  } finally {
    Pop-Location
  }
}

Write-Output $libraries[0].FullName
