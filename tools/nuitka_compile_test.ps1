# Experimental Windows Nuitka standalone build. Not used by release CI.
# Prerequisites: .venv with ".[agent,camera,gui]" plus `pip install nuitka`.
# -SkipBuild only verifies/repairs the Qt plugins of an existing build-nuitka\mybot.dist.
param([switch]$SkipBuild)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$Python = Join-Path $Root ".venv\Scripts\python.exe"
$Dist = Join-Path $Root "build-nuitka\mybot.dist"
$QtPlugins = @("platforms", "styles", "imageformats", "iconengines")

Push-Location $Root
try {
    if (-not $SkipBuild) {
        & $Python -m nuitka tools\entry_cli.py `
           --mode=standalone --msvc=latest --assume-yes-for-downloads `
           --output-dir=build-nuitka --output-folder-name=mybot --output-filename=pymybot.exe `
           --windows-console-mode=force --windows-icon-from-ico=tools\icon.ico `
           --enable-plugins=pyside6 `
           --include-qt-plugins=$($QtPlugins -join ",") `
           --include-module=lupa.luajit21 `
           --include-package=serial --include-package=pyftdi --include-package=PIL --include-package=av `
           --include-package=openai --include-package=anthropic `
           --include-package=pydantic_ai --include-package=httpx2 `
           --include-package-data=genai_prices `
           --include-distribution-metadata=pydantic-ai-slim --include-distribution-metadata=pydantic-graph `
           --include-distribution-metadata=pydantic --include-distribution-metadata=openai `
           --include-distribution-metadata=anthropic --include-distribution-metadata=genai-prices `
           --include-distribution-metadata=httpx2 --include-distribution-metadata=httpcore2 `
           --include-distribution-metadata=lupa --include-distribution-metadata=sqlparse `
           --include-distribution-metadata=pyserial --include-distribution-metadata=pyftdi `
           --include-distribution-metadata=pillow --include-distribution-metadata=av `
           --include-data-dir=modules=pymybot/assets/modules `
           --include-data-dir=robots=pymybot/assets/robots `
           --include-data-dir=scripts=pymybot/assets/scripts `
           --include-data-dir=skills=pymybot/assets/skills `
           --include-data-dir=prompts=pymybot/assets/prompts `
           --include-data-dir=robots=robots --include-data-dir=scripts=scripts `
           --include-data-files=README.md=README.md --include-data-files=LICENSE=LICENSE `
           --noinclude-custom-mode=genai_prices.data:bytecode `
           --noinclude-custom-mode=openai.types:bytecode `
           --noinclude-custom-mode=anthropic.types:bytecode
        if ($LASTEXITCODE -ne 0) { throw "Nuitka failed with exit code $LASTEXITCODE" }

        # Nuitka excludes Python source from data directories; native drivers load it at runtime.
        $AssetModules = Join-Path $Dist "pymybot\assets\modules"
        if (-not (Test-Path $AssetModules)) { throw "Missing packaged module assets: $AssetModules" }
        Copy-Item (Join-Path $Root "modules\*.py") $AssetModules -Force
    }

    if (-not (Test-Path (Join-Path $Dist "pymybot.exe"))) { throw "No build at $Dist" }

    # Nuitka's pyside6 plugin copies plugins here and points QCoreApplication at
    # them on import. A build without that plugin starts with "Could not find the
    # Qt platform plugin 'windows'", so copy them and pin the path in qt.conf.
    $Target = Join-Path $Dist "PySide6\qt-plugins"
    if (-not (Test-Path (Join-Path $Target "platforms\qwindows.dll"))) {
        Write-Warning "Qt platform plugin missing in $Target; copying from the venv"
        $Source = (& $Python -c "import os, PySide6; print(os.path.join(os.path.dirname(PySide6.__file__), 'plugins'))").Trim()
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $Source "platforms\qwindows.dll"))) {
            throw "Cannot locate PySide6 plugins in the venv"
        }
        New-Item -ItemType Directory -Force -Path $Target | Out-Null
        foreach ($name in $QtPlugins) {
            $from = Join-Path $Source $name
            if (Test-Path $from) { Copy-Item -Recurse -Force $from $Target }
        }
    }
    # Qt reads qt.conf next to the executable before any Python code runs.
    Set-Content -Encoding ascii -Path (Join-Path $Dist "qt.conf") -Value "[Paths]`r`nPlugins = PySide6/qt-plugins"

    if (-not (Test-Path (Join-Path $Target "platforms\qwindows.dll"))) { throw "qwindows.dll still missing" }
    Write-Host "Qt plugins OK: $(((Get-ChildItem $Target -Directory).Name) -join ', ')"
    & $Python -I (Join-Path $Root "tools\ci_smoke.py") frozen --executable (Join-Path $Dist "pymybot.exe")
    if ($LASTEXITCODE -ne 0) { throw "Frozen prompt smoke failed with exit code $LASTEXITCODE" }
} finally {
    Pop-Location
}
