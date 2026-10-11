# HTML-звіт сканування з чеклістом: один файл без зовнішніх залежностей.

function ConvertTo-D9Html { param([string]$Text) [System.Net.WebUtility]::HtmlEncode([string]$Text) }

function ConvertTo-D9LinkHtml {
    param($Link)
    $label = ConvertTo-D9Html $Link.label
    if ($Link.url -match '^https?://') { return "<a href=""$(ConvertTo-D9Html $Link.url)"" target=""_blank"" rel=""noopener"">$label ↗</a>" }
    # ms-settings:, windowsdefender:, *.msc — з браузера не відкриваються, показуємо як підказку
    return "<span class=""hint"">${label}: <code>$(ConvertTo-D9Html $Link.url)</code> (Win+R)</span>"
}

function ConvertTo-D9ScanHtml {
    param([Parameter(Mandatory)]$Scan, $Checklist, $Categories)
    $sev = @{
        critical   = @{ icon = '✖'; name = (T-D9 'Критично');         cls = 'crit' }
        warning    = @{ icon = '⚠'; name = (T-D9 'Варто виправити');  cls = 'warn' }
        suggestion = @{ icon = '💡'; name = (T-D9 'Поради');          cls = 'sugg' }
        info       = @{ icon = 'ℹ'; name = (T-D9 'Відомості');        cls = 'info' }
    }
    $verdictText = @{ good = (T-D9 'Добрий стан'); attention = (T-D9 'Потребує уваги'); serious = (T-D9 'Є серйозні проблеми') }[$Scan.score.verdict]
    $verdictCls  = @{ good = 'good'; attention = 'warn'; serious = 'crit' }[$Scan.score.verdict]
    $s = $Scan.system
    $disk = @{ hdd = 'HDD'; ssd = 'SSD'; nvme = 'NVMe SSD'; unknown = (T-D9 'не визначено') }[[string]$s.SystemDisk]

    $sb = New-Object Text.StringBuilder
    $w = { param($t) [void]$sb.AppendLine($t) }

    & $w "<!doctype html><html lang=""$script:D9Language""><head><meta charset=""utf-8""><meta name=""viewport"" content=""width=device-width,initial-scale=1"">"
    & $w "<title>$(T-D9 'Debora — звіт {0}' (ConvertTo-D9Html $Scan.id))</title>"
    & $w @'
<style>
:root{--bg:#f6f7f9;--card:#fff;--text:#1d2330;--muted:#5d6675;--line:#e3e6eb;--crit:#c62828;--warn:#b26a00;--sugg:#1565c0;--good:#2e7d32;--info:#5d6675}
@media (prefers-color-scheme:dark){:root{--bg:#14171c;--card:#1d2128;--text:#e7eaf0;--muted:#9aa3b2;--line:#2c323b;--crit:#ef5350;--warn:#ffb74d;--sugg:#64b5f6;--good:#81c784;--info:#9aa3b2}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:15px/1.5 "Segoe UI",system-ui,sans-serif}
main{max-width:920px;margin:0 auto;padding:24px 16px 48px}h1{font-size:22px;margin:0 0 4px}h2{font-size:18px;margin:32px 0 12px}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:16px 18px;margin:10px 0}
.muted{color:var(--muted)}.hero{display:flex;gap:24px;align-items:center;flex-wrap:wrap}
.score{font-size:48px;font-weight:700;line-height:1}.score small{font-size:18px;color:var(--muted);font-weight:400}
.verdict{font-weight:600}.good{color:var(--good)}.warn{color:var(--warn)}.crit{color:var(--crit)}.sugg{color:var(--sugg)}.info{color:var(--info)}
.cats{display:grid;grid-template-columns:repeat(auto-fill,minmax(190px,1fr));gap:8px 18px;margin-top:14px}
.cat{font-size:14px}.bar{height:6px;background:var(--line);border-radius:3px;overflow:hidden;margin-top:3px}.bar i{display:block;height:100%}
.sys{display:grid;grid-template-columns:max-content 1fr;gap:2px 16px;font-size:14px}
.f{border-left:4px solid var(--line)}.f.crit{border-left-color:var(--crit)}.f.warn{border-left-color:var(--warn)}.f.sugg{border-left-color:var(--sugg)}
.f .t{font-weight:600;color:var(--text)}.f .d{color:var(--muted);font-size:14px;margin-top:4px}.items{margin:6px 0 0 18px;padding:0;font-size:13px;color:var(--muted)}
.links{margin-top:6px;font-size:14px;display:flex;flex-wrap:wrap;gap:6px 16px}a{color:var(--sugg)}code{font-size:13px}.hint{color:var(--muted)}
ol.cl{list-style:none;padding:0;margin:0}ol.cl li{display:flex;gap:12px;padding:12px 0;border-top:1px solid var(--line)}ol.cl li:first-child{border-top:0}
.box{flex:0 0 22px;height:22px;border:2px solid var(--muted);border-radius:5px;display:flex;align-items:center;justify-content:center;font-size:14px}
.done .box{background:var(--good);border-color:var(--good);color:#fff}.done .t{text-decoration:line-through;color:var(--muted)}
.tag{display:inline-block;font-size:12px;padding:1px 8px;border-radius:10px;border:1px solid var(--line);color:var(--muted);margin-left:6px;font-weight:400}
@media print{body{background:#fff}.card{break-inside:avoid}}
</style></head><body><main>
'@
    & $w "<h1>$(T-D9 'Стан Windows: {0}' (ConvertTo-D9Html "$($s.Manufacturer) $($s.Model)"))</h1>"
    & $w "<div class=""muted"">$(ConvertTo-D9Html "$($s.OsName) $($s.DisplayVersion) ($($s.Build))") · $(T-D9 'сканування {0} · {1} с' ([datetime]$Scan.time).ToString('dd.MM.yyyy HH:mm') $Scan.durationSec)$(if ($Scan.deep) { ' · ' + (T-D9 'глибоке') })$(if (-not $Scan.admin) { ' · ' + (T-D9 'без прав адміністратора') })$(if ($Scan.hiddenCount) { ' · ' + (T-D9 'приховано вами: {0}' $Scan.hiddenCount) })</div>"

    & $w "<div class=""card""><div class=""hero""><div class=""score $verdictCls"">$($Scan.score.overall)<small> / 100</small></div><div><div class=""verdict $verdictCls"">$verdictText</div>"
    $counts = foreach ($k in 'critical', 'warning', 'suggestion') { $n = @($Scan.findings | Where-Object severity -eq $k).Count; if ($n) { "<span class=""$($sev[$k].cls)"">$($sev[$k].icon) $n $($sev[$k].name.ToLower())</span>" } }
    & $w "<div>$($counts -join ' · ')</div></div></div><div class=""cats"">"
    foreach ($c in $Categories) {
        $v = $Scan.score.categories.($c.id)
        if ($null -eq $v) { continue }
        $color = if ($v -ge 85) { 'var(--good)' } elseif ($v -ge 60) { 'var(--warn)' } else { 'var(--crit)' }
        & $w "<div class=""cat"">$(ConvertTo-D9Html (Get-D9Text $c.name)) <b>$v</b><div class=""bar""><i style=""width:$v%;background:$color""></i></div></div>"
    }
    & $w '</div></div>'

    if ($Checklist -and @($Checklist.items).Count) {
        $doneCount = @($Checklist.items | Where-Object status -eq 'done').Count
        & $w "<h2>$(T-D9 'Чекліст: що робити') <span class=""tag"">$(T-D9 '{0} / {1} виконано' $doneCount @($Checklist.items).Count)</span></h2><div class=""card""><ol class=""cl"">"
        foreach ($i in $Checklist.items) {
            $cls = if ($i.status -eq 'done') { 'done' } else { '' }
            $mark = if ($i.status -eq 'done') { '✓' } else { '' }
            $kind = switch ($i.action.type) { 'manual' { T-D9 'вручну' } 'tweaks' { T-D9 'автоматично · {0} налаштувань' @($i.action.ids).Count } 'actions' { T-D9 'автоматично · {0} виправлень' @($i.action.fixes).Count } 'apps' { T-D9 'автоматично · winget' } 'uninstall' { T-D9 'автоматично · видалення' } 'restorePoint' { T-D9 'автоматично' } default { T-D9 'автоматично' } }
            & $w "<li class=""$cls""><div class=""box"">$mark</div><div><div class=""t"">$($i.number). $(ConvertTo-D9Html $i.title)<span class=""tag"">$kind</span></div>"
            if ($i.why) { & $w "<div class=""d muted"">$(ConvertTo-D9Html $i.why)</div>" }
            $deps = @($i.dependsOn | ForEach-Object { $id = $_; ($Checklist.items | Where-Object id -eq $id).number } | Where-Object { $_ } | Sort-Object)
            if ($deps) { & $w "<div class=""d muted"">$(T-D9 'Після кроку {0}' ($deps -join ', '))</div>" }
            if (@($i.links).Count) { & $w "<div class=""links"">$((@($i.links) | ForEach-Object { ConvertTo-D9LinkHtml $_ }) -join '')</div>" }
            & $w '</div></li>'
        }
        & $w ('</ol></div><p class="muted">' + (T-D9 'Автоматичні кроки виконує Debora: <code>Debora.ps1 -Checklist -Run All</code>. Галочки ставляться самі після перевірки.') + '</p>')
    }

    & $w "<h2>$(T-D9 'Знахідки')</h2>"
    if (-not @($Scan.findings).Count) { & $w "<div class=""card good"">$(T-D9 'Проблем не знайдено.')</div>" }
    foreach ($fi in $Scan.findings) {
        $m = $sev[$fi.severity]
        & $w "<div class=""card f $($m.cls)""><div class=""t""><span class=""$($m.cls)"">$($m.icon)</span> $(ConvertTo-D9Html $fi.title)</div>"
        if ($fi.details) { & $w "<div class=""d"">$(ConvertTo-D9Html $fi.details)</div>" }
        if ($fi.data -and @($fi.data.items).Count) { & $w "<ul class=""items"">$((@($fi.data.items) | ForEach-Object { "<li><code>$(ConvertTo-D9Html "$($_.path)")</code> — $(Format-D9Size ([long]$_.bytes))</li>" }) -join '')</ul>" }
        if (@($fi.links).Count) { & $w "<div class=""links"">$((@($fi.links) | ForEach-Object { ConvertTo-D9LinkHtml $_ }) -join '')</div>" }
        & $w '</div>'
    }

    & $w "<h2>$(T-D9 'Комп''ютер')</h2><div class=""card""><div class=""sys"">"
    foreach ($row in @(
        @((T-D9 'Система'), "$($s.OsName) $($s.DisplayVersion) ($($s.Build))"), @((T-D9 'Модель'), "$($s.Manufacturer) $($s.Model)"),
        @((T-D9 'Процесор'), (T-D9 '{0}, ядер: {1}' $s.Cpu $s.Cores)), @((T-D9 'Пам''ять'), (T-D9 '{0} ГБ' $s.RamGB)), @((T-D9 'Диск C:'), $disk),
        @((T-D9 'Завантаження'), "$($s.Firmware) / $($s.PartitionStyle)"), @((T-D9 'Рекомендований профіль'), $Scan.recommendation.Preset))) {
        & $w "<div class=""muted"">$($row[0])</div><div>$(ConvertTo-D9Html $row[1])</div>"
    }
    & $w '</div></div>'

    $skipped = @($Scan.checks | Where-Object { $_.status -in 'skipped', 'error' })
    if ($skipped) {
        & $w "<h2>$(T-D9 'Не перевірено')</h2><div class=""card muted"">"
        & $w (($skipped | ForEach-Object { "$(ConvertTo-D9Html $_.name): $(ConvertTo-D9Html $_.note)" }) -join '<br>')
        & $w '</div>'
    }
    & $w "<p class=""muted"">$(T-D9 'Звіт створено Debora {0}. Звіт зберігається лише на цьому комп''ютері.' $script:D9Version)</p></main></body></html>"
    return $sb.ToString()
}
