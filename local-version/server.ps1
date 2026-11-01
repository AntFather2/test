param(
    [string]$Prefix = 'http://localhost:8080/',
    [string]$DataFile
)
# 대학 합격/불합격 관리 서버 (Windows PowerShell 5.1, 추가 설치 불필요)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Web.Extensions
$root = $PSScriptRoot
if (-not $DataFile) { $DataFile = Join-Path $root 'data.json' }
$ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$ser.MaxJsonLength = [int]::MaxValue
$utf8 = New-Object System.Text.UTF8Encoding($false)
$sessions = @{}
$RESULTS = @('합격', '불합격', '예비', '추가합격', '등록', '미발표')

function New-Salt { [guid]::NewGuid().ToString('N') }
function Get-Hash($salt, $pw) {
    $sha = [Security.Cryptography.SHA256]::Create()
    (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($salt + $pw)) | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Load-Db {
    if (Test-Path $DataFile) {
        $d = $ser.DeserializeObject([IO.File]::ReadAllText($DataFile, $utf8))
        foreach ($k in 'classes', 'students', 'results') { $d[$k] = [System.Collections.ArrayList]@($d[$k]) }
        return $d
    }
    $salt = New-Salt
    @{
        adminSalt = $salt; adminHash = (Get-Hash $salt 'admin1234'); viewerCode = ''
        nextId = 1; classes = [System.Collections.ArrayList]@(); students = [System.Collections.ArrayList]@(); results = [System.Collections.ArrayList]@()
    }
}
function Save-Db {
    $tmp = $DataFile + '.tmp'
    [IO.File]::WriteAllText($tmp, $ser.Serialize($db), $utf8)
    Move-Item -Force $tmp $DataFile
}
function Next-Id { $id = [int]$db['nextId']; $db['nextId'] = $id + 1; $id }
function Fail($code, $msg) { throw "${code}:$msg" }

$db = Load-Db
Save-Db

function Find-ById($list, $id) { foreach ($i in $list) { if ($i['id'] -eq $id) { return $i } }; return $null }
function Require-ClassAccess($s, $classId) {
    if (-not $s) { Fail 401 '로그인이 필요합니다.' }
    if ($s.role -eq 'admin') { return }
    if ($s.classId -ne $classId) { Fail 403 '본인 반만 수정할 수 있습니다.' }
}
function Has-ViewAccess($req, $s) {
    if ($s) { return $true }
    if ([string]::IsNullOrEmpty($db['viewerCode'])) { return $true }
    return ($req.Headers['X-Viewer'] -ceq $db['viewerCode'])
}
function Remove-StudentCascade($sid) {
    for ($i = $db['results'].Count - 1; $i -ge 0; $i--) { if ($db['results'][$i]['studentId'] -eq $sid) { $db['results'].RemoveAt($i) } }
    for ($i = $db['students'].Count - 1; $i -ge 0; $i--) { if ($db['students'][$i]['id'] -eq $sid) { $db['students'].RemoveAt($i) } }
}
function Pub-Class($c) { @{ id = $c['id']; grade = $c['grade']; num = $c['num'] } }

function Handle($req, $body) {
    $m = $req.HttpMethod; $p = $req.Url.AbsolutePath
    $s = $null; $t = $req.Headers['X-Token']
    if ($t -and $sessions.ContainsKey($t)) { $s = $sessions[$t] }

    if ($m -eq 'GET' -and $p -eq '/api/info') {
        $cl = @(); foreach ($c in $db['classes']) { $cl += , (Pub-Class $c) }
        return @{ viewerProtected = (-not [string]::IsNullOrEmpty($db['viewerCode'])); classes = $cl; results = $RESULTS }
    }
    if ($m -eq 'POST' -and $p -eq '/api/login') {
        Start-Sleep -Milliseconds 400
        if ($body.role -eq 'admin') {
            if ((Get-Hash $db['adminSalt'] ([string]$body.password)) -ne $db['adminHash']) { Fail 401 '비밀번호가 올바르지 않습니다.' }
            $tok = New-Salt; $sessions[$tok] = @{ role = 'admin'; classId = 0 }
            return @{ token = $tok; role = 'admin' }
        }
        $c = Find-ById $db['classes'] ([int]$body.classId)
        if (-not $c -or (Get-Hash $c['salt'] ([string]$body.password)) -ne $c['hash']) { Fail 401 '반 또는 비밀번호가 올바르지 않습니다.' }
        $tok = New-Salt; $sessions[$tok] = @{ role = 'teacher'; classId = $c['id'] }
        return @{ token = $tok; role = 'teacher'; classId = $c['id'] }
    }
    if ($m -eq 'POST' -and $p -eq '/api/viewer-check') {
        if (-not (Has-ViewAccess $req $s)) { Fail 401 '열람 코드가 필요합니다.' }
        return @{ ok = $true }
    }
    if ($m -eq 'GET' -and $p -eq '/api/data') {
        if (-not (Has-ViewAccess $req $s)) { Fail 401 '열람 코드가 필요합니다.' }
        $cl = @(); foreach ($c in $db['classes']) { $cl += , (Pub-Class $c) }
        return @{ classes = $cl; students = $db['students']; results = $db['results'] }
    }
    if (-not $s) { Fail 401 '로그인이 필요합니다.' }

    switch ("$m $p") {
        'POST /api/result' {
            $st = Find-ById $db['students'] ([int]$body.studentId)
            if (-not $st) { Fail 404 '학생을 찾을 수 없습니다.' }
            Require-ClassAccess $s $st['classId']
            $univ = ([string]$body.univ).Trim()
            if (-not $univ) { Fail 400 '대학명을 입력하세요.' }
            if ($RESULTS -notcontains [string]$body.result) { Fail 400 '결과 값이 올바르지 않습니다.' }
            $now = (Get-Date).ToString('yyyy-MM-dd HH:mm')
            $fields = @{ univ = $univ; major = ([string]$body.major).Trim(); admType = [string]$body.admType; result = [string]$body.result; note = ([string]$body.note).Trim(); updated = $now }
            if ($body.id) {
                $r = Find-ById $db['results'] ([int]$body.id)
                if (-not $r -or $r['studentId'] -ne $st['id']) { Fail 404 '기록을 찾을 수 없습니다.' }
                foreach ($k in $fields.Keys) { $r[$k] = $fields[$k] }
            } else {
                $fields['id'] = Next-Id; $fields['studentId'] = $st['id']
                [void]$db['results'].Add($fields)
            }
            Save-Db; return @{ ok = $true }
        }
        'POST /api/result/delete' {
            $r = Find-ById $db['results'] ([int]$body.id)
            if (-not $r) { Fail 404 '기록을 찾을 수 없습니다.' }
            $st = Find-ById $db['students'] $r['studentId']
            Require-ClassAccess $s $st['classId']
            [void]$db['results'].Remove($r); Save-Db; return @{ ok = $true }
        }
        'POST /api/students' {
            $cid = [int]$body.classId; Require-ClassAccess $s $cid
            if (-not (Find-ById $db['classes'] $cid)) { Fail 404 '반을 찾을 수 없습니다.' }
            $max = 0; foreach ($x in $db['students']) { if ($x['classId'] -eq $cid -and $x['no'] -gt $max) { $max = $x['no'] } }
            $added = 0
            foreach ($line in ([string]$body.text -split "`r?`n")) {
                $line = $line.Trim(); if (-not $line) { continue }
                if ($line -match '^(\d+)[\s,.\t]+(.+)$') { $no = [int]$Matches[1]; $name = $Matches[2].Trim() } else { $max++; $no = $max; $name = $line }
                if ($no -gt $max) { $max = $no }
                [void]$db['students'].Add(@{ id = (Next-Id); classId = $cid; no = $no; name = $name }); $added++
            }
            Save-Db; return @{ added = $added }
        }
        'POST /api/student/delete' {
            $st = Find-ById $db['students'] ([int]$body.id)
            if (-not $st) { Fail 404 '학생을 찾을 수 없습니다.' }
            Require-ClassAccess $s $st['classId']
            Remove-StudentCascade $st['id']; Save-Db; return @{ ok = $true }
        }
        'POST /api/admin/class' {
            if ($s.role -ne 'admin') { Fail 403 '관리자 전용입니다.' }
            $g = [int]$body.grade; $n = [int]$body.num
            if ($g -lt 1 -or $n -lt 1) { Fail 400 '학년/반을 확인하세요.' }
            if (([string]$body.password).Length -lt 4) { Fail 400 '비밀번호는 4자 이상이어야 합니다.' }
            foreach ($c in $db['classes']) { if ($c['grade'] -eq $g -and $c['num'] -eq $n) { Fail 409 '이미 있는 반입니다.' } }
            $salt = New-Salt
            [void]$db['classes'].Add(@{ id = (Next-Id); grade = $g; num = $n; salt = $salt; hash = (Get-Hash $salt ([string]$body.password)) })
            Save-Db; return @{ ok = $true }
        }
        'POST /api/admin/class/password' {
            if ($s.role -ne 'admin') { Fail 403 '관리자 전용입니다.' }
            $c = Find-ById $db['classes'] ([int]$body.classId)
            if (-not $c) { Fail 404 '반을 찾을 수 없습니다.' }
            if (([string]$body.password).Length -lt 4) { Fail 400 '비밀번호는 4자 이상이어야 합니다.' }
            $c['salt'] = New-Salt; $c['hash'] = Get-Hash $c['salt'] ([string]$body.password)
            Save-Db; return @{ ok = $true }
        }
        'POST /api/admin/class/delete' {
            if ($s.role -ne 'admin') { Fail 403 '관리자 전용입니다.' }
            $cid = [int]$body.classId
            $ids = @(); foreach ($x in $db['students']) { if ($x['classId'] -eq $cid) { $ids += $x['id'] } }
            foreach ($i in $ids) { Remove-StudentCascade $i }
            $c = Find-ById $db['classes'] $cid; if ($c) { [void]$db['classes'].Remove($c) }
            Save-Db; return @{ ok = $true }
        }
        'POST /api/admin/settings' {
            if ($s.role -ne 'admin') { Fail 403 '관리자 전용입니다.' }
            if ($null -ne $body.viewerCode) { $db['viewerCode'] = [string]$body.viewerCode }
            if ($body.adminPassword) {
                if (([string]$body.adminPassword).Length -lt 6) { Fail 400 '관리자 비밀번호는 6자 이상이어야 합니다.' }
                $db['adminSalt'] = New-Salt; $db['adminHash'] = Get-Hash $db['adminSalt'] ([string]$body.adminPassword)
            }
            Save-Db; return @{ ok = $true }
        }
    }
    Fail 404 '존재하지 않는 요청입니다.'
}

function Send($ctx, [int]$code, $bytes, $type) {
    $ctx.Response.StatusCode = $code
    $ctx.Response.ContentType = $type
    $ctx.Response.ContentLength64 = $bytes.Length
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $ctx.Response.OutputStream.Close()
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($Prefix)
$listener.Start()
Write-Host "서버 시작: $Prefix  (종료: Ctrl+C)"
Write-Host "초기 관리자 비밀번호: admin1234  (로그인 후 반드시 변경하세요)"

try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        try {
            $req = $ctx.Request; $path = $req.Url.AbsolutePath
            if ($path.StartsWith('/api/')) {
                $body = $null
                if ($req.HasEntityBody) {
                    $sr = New-Object IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)
                    $raw = $sr.ReadToEnd()
                    if ($raw) { $obj = $ser.DeserializeObject($raw); $body = New-Object PSObject; foreach ($k in $obj.Keys) { $body | Add-Member NoteProperty $k $obj[$k] } }
                }
                if (-not $body) { $body = New-Object PSObject }
                $res = Handle $req $body
                Send $ctx 200 ($utf8.GetBytes($ser.Serialize($res))) 'application/json; charset=utf-8'
            } elseif ($path -eq '/' -or $path -eq '/index.html') {
                Send $ctx 200 ([IO.File]::ReadAllBytes((Join-Path $root 'index.html'))) 'text/html; charset=utf-8'
            } else {
                Send $ctx 404 ($utf8.GetBytes('Not found')) 'text/plain'
            }
        } catch {
            $msg = $_.Exception.Message; $code = 500
            if ($msg -match '^(\d{3}):(.*)$') { $code = [int]$Matches[1]; $msg = $Matches[2] }
            else { Write-Host "오류: $msg" }
            try { Send $ctx $code ($utf8.GetBytes($ser.Serialize(@{ error = $msg }))) 'application/json; charset=utf-8' } catch {}
        }
    }
} finally { $listener.Stop() }
