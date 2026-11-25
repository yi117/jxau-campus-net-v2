' Silent launcher for the campus network guard.
' wscript has no console, so no window ever appears on the desktop.
' Called by the CampusNetGuard scheduled task; can also be double-clicked.
Option Explicit

Dim shell, baseDir, scriptPath, cmd
Set shell = CreateObject("WScript.Shell")

baseDir = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
scriptPath = baseDir & "guard.ps1"

cmd = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ & scriptPath & """ -Quiet"

' 0 = hidden window, True = wait for it to finish.
' Waiting matters: while the task shows "Running", the 5-minute repetition trigger
' is ignored (IgnoreNew), so no extra process is spawned every 5 minutes.
' When the guard exits, wscript exits too and the next trigger restarts it.
shell.Run cmd, 0, True
