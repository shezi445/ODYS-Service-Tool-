@echo off
setlocal
cd /d "%~dp0"

where flutter >nul 2>nul
if errorlevel 1 (
  echo Flutter was not found. Install Flutter stable and add its bin folder to PATH.
  exit /b 1
)

call flutter create --platforms=android,ios --project-name odys_service_tool --org com.odys .
if errorlevel 1 exit /b 1

call flutter pub get
if errorlevel 1 exit /b 1

call flutter analyze
if errorlevel 1 exit /b 1

call flutter test
if errorlevel 1 exit /b 1

node tool\verify_firmware.js
if errorlevel 1 exit /b 1
node tool\source_audit.js
if errorlevel 1 exit /b 1

if not exist android\key.properties (
  echo Release signing is not configured.
  echo Create android\key.properties and keep the keystore outside source control.
  exit /b 1
)

call flutter build apk --release --build-name 1.0.0 --build-number 110 --obfuscate --split-debug-info build\symbols
if errorlevel 1 exit /b 1

certutil -hashfile build\app\outputs\flutter-apk\app-release.apk SHA256 > build\app\outputs\flutter-apk\app-release.apk.sha256.txt

echo.
echo APK created:
echo %CD%\build\app\outputs\flutter-apk\app-release.apk
endlocal
