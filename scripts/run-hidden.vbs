' Starts pull-copy.ps1 from the same folder without a console window (for Windows Task Scheduler).
Set sh = CreateObject("WScript.Shell")
Set fs = CreateObject("Scripting.FileSystemObject")
script = fs.GetParentFolderName(WScript.ScriptFullName) & "\pull-copy.ps1"
rc = sh.Run("powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & script & """", 0, True)
WScript.Quit rc
