@echo off
setlocal
chcp 65001 >nul

set "FW=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319"
if not exist "%FW%\csc.exe" set "FW=%WINDIR%\Microsoft.NET\Framework\v4.0.30319"
if not exist "%FW%\csc.exe" (
  echo 找不到 csc.exe，这台机器可能没装 .NET Framework 4.x。
  pause
  exit /b 1
)

rem WPF 程序集在 Framework 目录的 WPF 子目录里
set "WPF=%FW%\WPF"
if not exist "%WPF%\PresentationFramework.dll" (
  echo 找不到 WPF 程序集：%WPF%
  pause
  exit /b 1
)

echo 正在编译 GuardUI.exe ...
"%FW%\csc.exe" /nologo /target:winexe /codepage:65001 /optimize+ ^
  /out:GuardUI.exe ^
  /r:System.dll ^
  /r:System.Core.dll ^
  /r:System.Xml.dll ^
  /r:System.Xaml.dll ^
  /r:System.Web.Extensions.dll ^
  /r:System.Management.dll ^
  /r:System.Security.dll ^
  "/r:%WPF%\WindowsBase.dll" ^
  "/r:%WPF%\PresentationCore.dll" ^
  "/r:%WPF%\PresentationFramework.dll" ^
  /resource:GuardUI.xaml,GuardUI.xaml ^
  GuardUI.cs

if errorlevel 1 (
  echo.
  echo 编译失败。
  pause
  exit /b 1
)

echo.
echo 编译完成：GuardUI.exe
echo 双击即可运行；界面会自动找同目录或 ..\campus-net 下的 guard.ps1。
pause
