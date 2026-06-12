@echo off
REM PATH shim installed by Chocolatey. Forwards all arguments to the PowerShell
REM launcher, which runs Invoke-TfvcMigration. Using -File keeps argument
REM quoting intact for paths with spaces.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tfvc2git.ps1" %*
