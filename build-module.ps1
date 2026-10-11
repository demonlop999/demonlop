$ErrorActionPreference = "Stop"

$moduleRoot = $PSScriptRoot
$androidProject = Join-Path $moduleRoot "android-app"
$apkPath = Join-Path $androidProject "app\build\outputs\apk\debug\app-debug.apk"
$moduleApkPath = Join-Path $moduleRoot "app\UltraGamingMode.apk"
$archivePath = Join-Path $moduleRoot "UltraGamingMode-v3.3.1.zip"

if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
    throw "Node.js et npm sont requis pour compiler l'interface WebUI."
}
if (-not (Get-Command java -ErrorAction SilentlyContinue)) {
    throw "Java 17 ou plus récent est requis. Installez un JDK et configurez JAVA_HOME."
}
if (-not (Get-Command gradle -ErrorAction SilentlyContinue)) {
    throw "Gradle est requis. Installez Gradle 8.9+ puis relancez ce script."
}
if (-not ($env:ANDROID_HOME -or $env:ANDROID_SDK_ROOT)) {
    throw "Android SDK introuvable. Définissez ANDROID_HOME ou ANDROID_SDK_ROOT."
}
$sdkRoot = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { $env:ANDROID_SDK_ROOT }
if (-not (Test-Path -LiteralPath (Join-Path $sdkRoot "platforms\android-35\android.jar"))) {
    throw "La plateforme Android SDK 35 est requise. Installez Android 15 (API 35) depuis le SDK Manager."
}

Push-Location $moduleRoot
try {
    if (-not (Test-Path -LiteralPath (Join-Path $moduleRoot "node_modules\esbuild\bin\esbuild"))) {
        & npm ci
        if ($LASTEXITCODE -ne 0) {
            throw "La restauration des dépendances WebUI a échoué (code $LASTEXITCODE)."
        }
    }
    & npm run build
    if ($LASTEXITCODE -ne 0) {
        throw "La compilation de la WebUI a échoué (code $LASTEXITCODE)."
    }
} finally {
    Pop-Location
}

Push-Location $androidProject
try {
    & gradle --no-daemon assembleDebug
    if ($LASTEXITCODE -ne 0) {
        throw "La compilation Android a échoué (code $LASTEXITCODE)."
    }
} finally {
    Pop-Location
}

if (-not (Test-Path -LiteralPath $apkPath)) {
    throw "APK compilé introuvable: $apkPath"
}

New-Item -ItemType Directory -Force -Path (Split-Path $moduleApkPath -Parent) | Out-Null
Copy-Item -LiteralPath $apkPath -Destination $moduleApkPath -Force

if (Test-Path -LiteralPath $archivePath) {
    Remove-Item -LiteralPath $archivePath -Force
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$stream = [System.IO.File]::Open($archivePath, [System.IO.FileMode]::CreateNew)
try {
    $archive = [System.IO.Compression.ZipArchive]::new(
        $stream,
        [System.IO.Compression.ZipArchiveMode]::Create
    )
    try {
        Get-ChildItem -LiteralPath $moduleRoot -File -Recurse |
            Where-Object {
                ($_.FullName -notmatch '\\node_modules\\|\\android-app\\\.gradle\\|\\android-app\\app\\build\\|\\\.git\\') -and
                ($_.Name -notmatch '^UltraGamingMode-v[\d.]+\.zip$')
            } |
            ForEach-Object {
                $relative = [System.IO.Path]::GetRelativePath($moduleRoot, $_.FullName).Replace('\', '/')
                if ($relative -match '\.sh$|^module\.prop$|^META-INF/com/google/android/(update-binary|updater-script)$') {
                    $content = [System.IO.File]::ReadAllText($_.FullName) -replace "`r`n?", "`n"
                    $entry = $archive.CreateEntry($relative, [System.IO.Compression.CompressionLevel]::Optimal)
                    $writer = [System.IO.StreamWriter]::new(
                        $entry.Open(),
                        [System.Text.UTF8Encoding]::new($false)
                    )
                    try {
                        $writer.Write($content)
                    } finally {
                        $writer.Dispose()
                    }
                } else {
                    $entry = [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                        $archive,
                        $_.FullName,
                        $relative,
                        [System.IO.Compression.CompressionLevel]::Optimal
                    )
                }
                $entry.ExternalAttributes = if ($relative -match '\.sh$|^META-INF/com/google/android/update-binary$') {
                    -2115174400
                } else {
                    -2119958528
                }
            }
    } finally {
        $archive.Dispose()
    }
} finally {
    $stream.Dispose()
}

Write-Output "Module Magisk créé: $archivePath"
