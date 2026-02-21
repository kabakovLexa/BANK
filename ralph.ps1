param(
  [int]$MaxIterations = 51,
  [string]$ProjectDir = "C:\Project",
  [string]$Agent = "solution-architect",
  [string]$TasksFile = "tasks.json",
  [string]$ProgressFile = "progress.md"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---- UTF-8 для консоли/вывода (чтобы не было кракозябр) ----
try { chcp 65001 | Out-Null } catch {}
$OutputEncoding = [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

Set-Location $ProjectDir

if (-not (Test-Path $TasksFile)) { throw "Не найден $TasksFile в $ProjectDir" }
if (-not (Test-Path $ProgressFile)) {
  "# Progress Log`n" | Set-Content -Encoding UTF8 $ProgressFile
}

function Run-Claude([string]$prompt) {
  $claude = Join-Path $env:USERPROFILE ".local\bin\claude.exe"

  $args = @(
    "--agent", $Agent,
    "--permission-mode", "acceptEdits",
    "--add-dir", $ProjectDir,
    "-p", $prompt
  )

  & $claude @args
}

function Sleep-Until-Reset([string]$text) {
  # Ищем строку вида: "You've hit your limit … resets 4am (Europe/Moscow)"
  if ($text -notmatch "resets\s+(\d{1,2})(am|pm)\s+\(([^)]+)\)") { return $false }

  $hour12 = [int]$matches[1]
  $ampm   = $matches[2]
  $tzName = $matches[3]

  # 12h -> 24h
  $hour24 = $hour12 % 12
  if ($ampm -eq "pm") { $hour24 += 12 }

  # timezone
  try {
    $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById($tzName)
  } catch {
    # fallback для Windows (часто нет "Europe/Moscow")
    try { $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById("Russian Standard Time") }
    catch { return $false }
  }

  $nowTz = [System.TimeZoneInfo]::ConvertTime([DateTimeOffset]::UtcNow, $tz)
  $resetLocal = [DateTimeOffset]::new($nowTz.Year, $nowTz.Month, $nowTz.Day, $hour24, 0, 0, $nowTz.Offset)

  if ($resetLocal -le $nowTz) { $resetLocal = $resetLocal.AddDays(1) }

  # запас 30 секунд
  $sleepSeconds = [Math]::Max(30, [int]($resetLocal - $nowTz).TotalSeconds + 30)

  Write-Host "Limit reached. Sleeping until reset time ($($resetLocal.ToString('u'))) ~ $sleepSeconds sec..."
  Start-Sleep -Seconds $sleepSeconds
  return $true
}

for ($i = 1; $i -le $MaxIterations; $i++) {
  Write-Host "===== Iteration $i ====="

  $prompt = @"
@$TasksFile @$ProgressFile
Ты работаешь в проекте $ProjectDir.

1) Открой tasks.json и выбери одну задачу:
   - status = pending
   - самый высокий priority (critical > high > medium > low)
   - dependencies либо пустые, либо все dependencies уже done
   Работай ТОЛЬКО над этой одной задачей.

2) Перед завершением проверь проект:
   - Если есть pom.xml → запусти `mvn -q test`
   - Если есть build.gradle или build.gradle.kts → запусти `.\gradlew test` (если gradlew существует), иначе `gradle test`
   - Если билд/тесты запустить нельзя → объясни коротко почему и что проверил.

3) Обнови tasks.json:
   - добавь заметки/результаты
   - меняй status на done только если задача реально выполнена и проверки прошли

4) Добавь запись в progress.md по шаблону.

5) Если это git-репозиторий (есть .git) — сделай git commit для этой задачи.

РАБОТАЙ ТОЛЬКО НАД ОДНОЙ ЗАДАЧЕЙ.
Если задача завершена, в конце ответа выведи строку: <promise>COMPLETE</promise>
"@

  $out = Run-Claude $prompt
  Write-Host $out

  if (Sleep-Until-Reset $out) {
    # после сна просто пробуем следующую итерацию
    continue
  }

  if ($out -match "<promise>COMPLETE</promise>") {
    Write-Host "Task complete."
    break
  }
}

Write-Host "Done."