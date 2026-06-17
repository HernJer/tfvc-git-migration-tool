<#
.SYNOPSIS
    Returns the standard Visual Studio .gitignore template.
.DESCRIPTION
    TFVC source rarely contains a .gitignore, so the migration can add one for
    future use. Single-quoted here-string (literal) - the template contains '$'
    (e.g. $tf/) which must not be treated as PowerShell variables. Not exported.
#>

function Get-VisualStudioGitignore {
    return @'
## Visual Studio .gitignore (added by tfvc2git)
## https://github.com/github/gitignore/blob/main/VisualStudio.gitignore

# User-specific files
*.rsuser
*.suo
*.user
*.userosscache
*.sln.docstates

# Build results
[Dd]ebug/
[Dd]ebugPublic/
[Rr]elease/
[Rr]eleases/
x64/
x86/
[Ww][Ii][Nn]32/
[Aa][Rr][Mm]/
[Aa][Rr][Mm]64/
bld/
[Bb]in/
[Oo]bj/
[Ll]og/
[Ll]ogs/

# Visual Studio cache/options directory
.vs/

# MSTest / test results
[Tt]est[Rr]esult*/
[Bb]uild[Ll]og.*
*.VisualState.xml
TestResult.xml
nunit-*.xml

# Build outputs
*_i.c
*_p.c
*_h.h
*.ilk
*.meta
*.obj
*.iobj
*.pch
*.pdb
*.ipdb
*.pgc
*.pgd
*.rsp
*.sbr
*.tlb
*.tli
*.tlh
*.tmp
*.tmp_proj
*_wpftmp.csproj
*.log
*.tlog
*.vspscc
*.vssscc
.builds
*.pidb
*.svclog
*.scc

# Visual C++
ipch/
*.aps
*.ncb
*.opendb
*.opensdf
*.sdf
*.cachefile
*.VC.db
*.VC.VC.opendb

# Profiler
*.psess
*.vsp
*.vspx
*.sap

# Visual Studio Trace Files
*.e2e

# ReSharper
_ReSharper*/
*.[Rr]e[Ss]harper
*.DotSettings.user

# TeamCity
_TeamCity*

# DotCover
*.dotCover

# NCrunch
_NCrunch_*
.*crunch*.local.xml
nCrunchTemp_*

# NuGet
*.nupkg
*.snupkg
**/[Pp]ackages/*
!**/[Pp]ackages/build/
*.nuget.props
*.nuget.targets

# Microsoft Azure
csx/
*.build.csdef
ecf/
rcf/

# Windows Store app package directories and files
AppPackages/
BundleArtifacts/
Package.StoreAssociation.xml
_pkginfo.txt
*.appx
*.appxbundle
*.appxupload

# Others
ClientBin/
~$*
*~
*.dbmdl
*.dbproj.schemaview
*.jfm
*.pfx
*.publishsettings
orleans.codegen.cs
node_modules/
*.[Cc]ache
!?*.[Cc]ache/

# TFS / Team Foundation local workspace cache
$tf/
*.plg
*.opt
*.vbw

# JetBrains Rider
*.sln.iml
.idea/

# Backup & report files from converting an old project file
_UpgradeReport_Files/
Backup*/
UpgradeLog*.XML
UpgradeLog*.htm
ServiceFabricBackup/
*.rptproj.bak

# SQL Server files
*.mdf
*.ldf
*.ndf
'@
}
