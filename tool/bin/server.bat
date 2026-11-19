@echo off
setlocal EnableExtensions

set "ROOT_DIR=%~dp0..\.."
set "TOOL_DIR=%ROOT_DIR%\tool"

if not "%DART%"=="" (
  set "DART_CMD=%DART%"
  goto :run
)

where fvm >nul 2>nul
if %ERRORLEVEL%==0 (
  if exist "%ROOT_DIR%\.fvmrc" (
    set "DART_CMD=fvm dart"
    goto :run
  )
  if exist "%ROOT_DIR%\.fvm\fvm_config.json" (
    set "DART_CMD=fvm dart"
    goto :run
  )
)

where flutter >nul 2>nul
if %ERRORLEVEL%==0 (
  for /f "delims=" %%F in ('where flutter') do (
    set "FLUTTER_BIN=%%F"
    goto :found_flutter
  )
)
:found_flutter
if defined FLUTTER_BIN (
  for %%D in ("%FLUTTER_BIN%") do set "DART_CMD=%%~dpDdart.exe"
  if exist "%DART_CMD%" goto :run
)

where dart >nul 2>nul
if %ERRORLEVEL%==0 (
  set "DART_CMD=dart"
  goto :run
)

echo ❌ 未找到 dart。请安装 Flutter SDK，或设置 DART 环境变量。
exit /b 1

:run
pushd "%TOOL_DIR%"
if not exist ".dart_tool\package_config.json" (
  echo ℹ️  首次运行，正在执行 dart pub get ...
  %DART_CMD% pub get
  if errorlevel 1 exit /b 1
)

%DART_CMD% run bin/server.dart %*
set "EXIT_CODE=%ERRORLEVEL%"
popd
exit /b %EXIT_CODE%
