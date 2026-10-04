# commit-with-date.ps1 — 按指定时间戳提交
#
# 用法:
#   .\commit-with-date.ps1 -Repo D:\path -Date "2026-10-02 09:14:00" -Message "feat: xxx"
#   .\commit-with-date.ps1 -Repo D:\path -Date "..." -Message "..." -Paths "src/a.mbt","src/b.mbt"
#
# 并行开发的多个 agent 共用一个工作区时，**一定要用 -Paths 精确指定文件**。
# 不加 -Paths 会退化成 `git add -A`，把其他 agent 的在制品一起卷进你的提交。
param(
  [Parameter(Mandatory=$true)][string]$Repo,
  [Parameter(Mandatory=$true)][string]$Date,
  [Parameter(Mandatory=$true)][string]$Message,
  [string[]]$Paths = @()
)

Push-Location $Repo
try {
  $env:GIT_AUTHOR_DATE    = $Date
  $env:GIT_COMMITTER_DATE = $Date

  if ($Paths.Count -gt 0) {
    # 精确模式：只 stage 指定路径
    foreach ($p in $Paths) {
      git add -- $p
    }
  } else {
    Write-Warning "no -Paths given, falling back to 'git add -A' (may capture other agents' work in progress)"
    git add -A
  }

  $staged = git diff --cached --name-only
  if ([string]::IsNullOrWhiteSpace($staged)) {
    Write-Output "nothing staged, skipped"
  } else {
    Write-Output "staging:"
    $staged | ForEach-Object { Write-Output "  $_" }
    git commit -q -m $Message
    Write-Output "committed: $Message @ $Date"
  }
}
finally {
  Remove-Item Env:\GIT_AUTHOR_DATE -ErrorAction SilentlyContinue
  Remove-Item Env:\GIT_COMMITTER_DATE -ErrorAction SilentlyContinue
  Pop-Location
}
