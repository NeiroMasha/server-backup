# Компьютер сам забирает с сервера аварийный архив и хранит несколько версий. Для Windows.
# Сервер не знает, где лежит эта копия, и зайти сюда не может: её не сотрёт ни взломщик сервера, ни авария у хостинга.
# Запуск раз в сутки через Планировщик заданий Windows (как завести — в SKILL.md).

# --- Настройки ---
$Server  = 'root@АДРЕС_СЕРВЕРА'
$SshKey  = "$env:USERPROFILE\.ssh\КЛЮЧ_ОТ_СЕРВЕРА"
$Dest    = "$env:USERPROFILE\server-backup\copies"
$Keep    = 7
$Remote  = '/var/backups/server-backup/emergency'
# -----------------

$ErrorActionPreference = 'Stop'
$log  = "$env:USERPROFILE\server-backup\pull.log"
$name = 'emergency.tar.zst.enc'
$tmp  = "$Dest\$name.tmp"
$ssh  = @('-i', $SshKey, '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=20', '-o', 'ServerAliveInterval=30')

function Log($m) { [IO.File]::AppendAllText($log, "$(Get-Date -Format 's') $m`r`n", [Text.Encoding]::UTF8) }

# ssh вызываем с -n: без консоли (из Планировщика) Windows OpenSSH иначе вечно ждёт ввода.
# Успех определяем по коду выхода: в PowerShell 5.1 любая строка в stderr иначе становится исключением.
function Invoke-Native($exe, [string[]]$argList) {
    $ErrorActionPreference = 'Continue'
    $out = & $exe @argList 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) { throw "$exe завершился с кодом ${LASTEXITCODE}: $($out -join ' ')" }
    $out
}

try {
    New-Item -ItemType Directory -Force $Dest | Out-Null
    $remoteSum = ((Invoke-Native 'ssh' ($ssh + @('-n', $Server, "cat $Remote/emergency.sha256"))) -join '').Trim()
    if ($remoteSum -notmatch '^[0-9a-f]{64}$') { throw 'С сервера пришла странная контрольная сумма, архив не беру' }

    $last = Get-ChildItem -LiteralPath $Dest -Filter 'emergency-*.tar.zst.enc' | Sort-Object Name -Descending | Select-Object -First 1
    if ($last -and (Get-FileHash -Algorithm SHA256 -LiteralPath $last.FullName).Hash.ToLower() -eq $remoteSum) {
        Log 'Нового архива нет'
    } else {
        Invoke-Native 'scp' ($ssh + @('-q', "${Server}:$Remote/$name", $tmp)) | Out-Null
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath $tmp).Hash.ToLower() -ne $remoteSum) { throw 'Контрольная сумма не сошлась, архив не принят' }
        Move-Item -LiteralPath $tmp -Destination "$Dest\emergency-$(Get-Date -Format 'yyyy-MM-dd_HHmm').tar.zst.enc"
        Invoke-Native 'scp' ($ssh + @('-q', "${Server}:$Remote/inventory.txt", "$Dest\inventory.txt")) | Out-Null
        # Старые версии убираем только после того, как новая легла целиком.
        Get-ChildItem -LiteralPath $Dest -Filter 'emergency-*.tar.zst.enc' | Sort-Object Name -Descending |
            Select-Object -Skip $Keep | Remove-Item
        Log 'OK: новый архив принят'
    }
    # Отметка для сервера: по ней он заметит и напишет, если компьютер перестал забирать архив.
    Invoke-Native 'ssh' ($ssh + @('-n', $Server, "echo `$(date +%s) OK >> $Remote/pulled.log")) | Out-Null
}
catch {
    Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    Log "ОШИБКА: $($_.Exception.Message)"
    exit 1
}
