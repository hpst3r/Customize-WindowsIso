@echo off
rem DiskPicker: choose the disk Windows is installed on, partition it, then run Setup.
rem
rem winpeshl.ini in the Setup image of boot.wim runs this instead of X:\setup.exe.
rem   - exactly one internal disk of at least DP_MIN_GB: wipe it and install, no questions
rem   - several: numbered menu; the technician picks one (or lets Setup show its own page)
rem   - none: explain (usually a missing storage driver) and offer a driver load / prompt
rem
rem Only cmd, diskpart, reg, wpeutil and drvload are used: the Setup image has no findstr,
rem choice, timeout or wmic, and Server 2022's has no PowerShell.
rem
rem Customize-Iso.ps1 adds settings.cmd (DP_MIN_GB) and unattend-head.xml/unattend-tail.xml:
rem the media's answer file split where <InstallTo> goes, so the chosen disk can be put in.
rem
rem Testing outside WinPE: set DP_TEST_DIR to a folder with list.txt and detail-<n>.txt
rem (captured diskpart output) and unattend-head.xml/unattend-tail.xml. Nothing is
rem partitioned, Setup is not started, and empty input ends the script.

setlocal EnableExtensions EnableDelayedExpansion

set "DP=%~dp0"
set "WORK=%DP%work"
set "TEMPLATE=%DP%"
set "TEST="
if defined DP_TEST_DIR (
  set "TEST=1"
  set "WORK=%DP_TEST_DIR%\work"
  set "TEMPLATE=%DP_TEST_DIR%\"
)

rem refuse to run anywhere but WinPE: this script wipes disks
if not defined TEST (
  if /i not "%SystemDrive%"=="X:" goto :notWinPE
  reg query "HKLM\SYSTEM\CurrentControlSet\Control\MiniNT" >nul 2>&1 || goto :notWinPE
)

if exist "%DP%settings.cmd" call "%DP%settings.cmd"
if not defined DP_MIN_GB set "DP_MIN_GB=50"

if not exist "%WORK%" md "%WORK%"
set "LOG=%WORK%\diskpicker.log"
title Windows Setup - choose a disk

set "SETUP=%SystemDrive%\setup.exe"
if not exist "%SETUP%" set "SETUP=%SystemDrive%\sources\setup.exe"

echo(
echo  Starting Windows Setup...
call :log DiskPicker started, minimum size %DP_MIN_GB% GB
rem winpeshl skips startnet.cmd when winpeshl.ini exists: install devices (storage
rem drivers included) and start networking, as WinPE normally does
if not defined TEST wpeinit
call :firmware
call :log firmware %FIRMWARE%

set "FORCEMENU="

:rescan
call :scan
if "%NPICK%"=="0" goto :menu
if defined FORCEMENU goto :menu
if "%NAUTO%"=="1" (
  for %%n in (%AUTO%) do set "T=%%n"
  call :log one eligible disk: !T!
  goto :install
)
goto :menu

rem ------------------------------------------------------------------ menu

:menu
cls
echo(
echo  ==========================================================================
echo   Windows Setup: choose the disk to install Windows on
echo  ==========================================================================
echo(
if "%NPICK%"=="0" (
  echo   No disk was found that Windows can be installed on.
  echo(
  echo   Usually Setup has no driver for the storage controller: Intel RST/VMD,
  echo   RAID or some NVMe controllers on PCs, virtio-scsi/virtio-blk on VMs.
  echo   Load the driver with L, or let Setup show its own page ^(S^), which also
  echo   has "Load driver".
) else (
  echo   The disk you choose is ERASED: all partitions on it are deleted.
  echo   Other disks are not touched.
  echo(
  echo     Disk  Size      Bus     Model
  echo     ----  --------  ------  ------------------------------------------
  for %%n in (%PICKABLE%) do call :showDisk %%n
)
if defined OTHERS (
  echo(
  echo   Not available:
  for %%n in (%OTHERS%) do call :showOther %%n
)
echo(
if not "%NPICK%"=="0" echo   Type a disk number to erase it and install Windows on it, or:
echo     S  run Setup and choose or partition the disk there
echo     L  load a storage driver ^(.inf^), then rescan
echo     R  rescan disks
echo     C  command prompt ^(type EXIT to come back here^)
echo     B  reboot     P  power off
echo(
set "ANSWER="
set /p "ANSWER=  Choice: "
if not defined ANSWER (
  if defined TEST (echo [test] no more input & exit /b 9)
  goto :menu
)
>> "%LOG%" echo [%date% %time%] menu answer: !ANSWER!
if /i "!ANSWER!"=="S" goto :setupOnly
if /i "!ANSWER!"=="L" goto :loadDriver
if /i "!ANSWER!"=="R" goto :rescan
if /i "!ANSWER!"=="C" goto :prompt
if /i "!ANSWER!"=="B" goto :reboot
if /i "!ANSWER!"=="P" goto :poweroff

set "T="
for %%n in (%PICKABLE%) do if "%%n"=="!ANSWER!" set "T=%%n"
if not defined T (
  echo(
  echo   "!ANSWER!" is not one of the choices above.
  call :pause
  goto :menu
)

echo(
echo   Disk !T!: !D_%T%_MODEL!, !D_%T%_SIZE!, !D_%T%_TYPE!
echo   ALL DATA ON THIS DISK WILL BE LOST.
set "OK="
set /p "OK=  Type YES to erase it and install Windows: "
if /i not "!OK!"=="YES" goto :menu
call :log disk !T! chosen and confirmed
goto :install

:loadDriver
echo(
echo   Path of the driver .inf, e.g. E:\drivers\vioscsi\w11\amd64\vioscsi.inf
echo   ^(use C for a prompt to look around first; empty to cancel^)
set "INF="
set /p "INF=  .inf: "
if not defined INF goto :menu
if defined TEST (echo [test] would run: drvload "!INF!") else drvload "!INF!"
call :pause
goto :rescan

:prompt
echo(
echo   Type EXIT to return to the disk menu.
if not defined TEST cmd /k
goto :rescan

:reboot
call :log reboot
if defined TEST (echo [test] would reboot & exit /b 0)
wpeutil reboot
exit /b 0

:poweroff
call :log power off
if defined TEST (echo [test] would power off & exit /b 0)
wpeutil shutdown
exit /b 0

rem ------------------------------------------------------------------ install

rem Wipe disk %T% with the same layout the media's answer file used to create on
rem disk 0 (UEFI: EFI 260 MB FAT32, MSR 16 MB, Windows NTFS) or, booted in BIOS
rem mode, MBR with a 100 MB active system partition. Then point Setup at it.
:install
echo(
echo   Installing Windows on disk %T%: !D_%T%_MODEL!, !D_%T%_SIZE!, !D_%T%_TYPE!
echo   Erasing and partitioning disk %T% ^(%FIRMWARE%^)...
set "SCRIPT=%WORK%\partition.txt"
if "%FIRMWARE%"=="BIOS" (
  set "PART=2"
  > "%SCRIPT%" (
    echo select disk %T%
    echo online disk noerr
    echo attributes disk clear readonly noerr
    echo clean
    echo convert mbr
    echo create partition primary size=100
    echo format quick fs=ntfs label="System"
    echo active
    echo create partition primary
    echo format quick fs=ntfs label="Windows"
  )
) else (
  set "PART=3"
  > "%SCRIPT%" (
    echo select disk %T%
    echo online disk noerr
    echo attributes disk clear readonly noerr
    echo clean
    echo convert gpt
    echo create partition efi size=260
    echo format quick fs=fat32 label="System"
    echo create partition msr size=16
    echo create partition primary
    echo format quick fs=ntfs label="Windows"
  )
)
call :log partitioning disk %T% for %FIRMWARE%, Windows on partition %PART%
if defined TEST (
  echo [test] would run diskpart with:
  type "%SCRIPT%"
) else (
  diskpart /s "%SCRIPT%" > "%WORK%\partition-output.txt" 2>&1
  if errorlevel 1 (
    type "%WORK%\partition-output.txt"
    call :log diskpart failed on disk %T%
    echo(
    echo   Partitioning disk %T% failed ^(output above^). Nothing was installed.
    call :pause
    set "FORCEMENU=1"
    goto :rescan
  )
)

rem answer file = media answer file with <InstallTo> set to the disk just partitioned
> "%WORK%\installto.xml" echo ^<DiskID^>%T%^</DiskID^>^<PartitionID^>%PART%^</PartitionID^>
copy /y /b "%TEMPLATE%unattend-head.xml" + "%WORK%\installto.xml" + "%TEMPLATE%unattend-tail.xml" "%WORK%\unattend.xml" >nul
if errorlevel 1 (
  call :log could not write the answer file
  echo   Could not write %WORK%\unattend.xml. Choose S to run Setup without it.
  call :pause
  set "FORCEMENU=1"
  goto :rescan
)
call :log running %SETUP% /unattend:%WORK%\unattend.xml
rem /unattend is supported from WinPE; UnattendFile is the first place Setup looks for
rem an answer file, in case the 24H2+ setup.exe doesn't hand the switch on
if defined TEST (
  echo [test] would run: "%SETUP%" /unattend:%WORK%\unattend.xml
  exit /b 0
)
reg add HKLM\SYSTEM\Setup /v UnattendFile /t REG_SZ /d "%WORK%\unattend.xml" /f >nul
start "" /wait "%SETUP%" /unattend:%WORK%\unattend.xml
goto :setupExited

rem Setup with the media's own answer file, which has no disk settings when the
rem picker is in use, so Setup shows its disk page
:setupOnly
call :log running %SETUP% without a disk
if defined TEST (
  echo [test] would run: "%SETUP%"
  exit /b 0
)
reg delete HKLM\SYSTEM\Setup /v UnattendFile /f >nul 2>&1
start "" /wait "%SETUP%"
goto :setupExited

rem Setup reboots the PC itself when it finishes. Exiting this script also reboots
rem (winpeshl), which is what happens without the picker when Setup is closed.
:setupExited
set "RC=%errorlevel%"
call :log setup exited with %RC%
if "%RC%"=="0" exit /b 0
echo(
echo   Windows Setup exited with code %RC%. Logs: X:\Windows\Panther\setupact.log
call :pause
set "FORCEMENU=1"
goto :rescan

:notWinPE
echo diskpicker.cmd only runs in Windows PE (it erases disks). Set DP_TEST_DIR to test it.
exit /b 1

rem ------------------------------------------------------------------ helpers

:log
>> "%LOG%" echo [%date% %time%] %*
goto :eof

rem FIRMWARE=UEFI or BIOS (PEFirmwareType 0x1 = BIOS, 0x2 = UEFI)
:firmware
set "FIRMWARE=UEFI"
if defined DP_TEST_FIRMWARE (
  set "FIRMWARE=%DP_TEST_FIRMWARE%"
  goto :eof
)
wpeutil UpdateBootInfo >nul 2>&1
for /f "tokens=3" %%v in ('reg query HKLM\System\CurrentControlSet\Control /v PEFirmwareType 2^>nul') do (
  if "%%v"=="0x1" set "FIRMWARE=BIOS"
)
goto :eof

rem Fill D_<n>_* for every disk; PICKABLE = disks that may be installed on,
rem AUTO = those of them at least DP_MIN_GB, OTHERS = the rest
:scan
for /f "delims==" %%v in ('set D_ 2^>nul') do set "%%v="
set "DISKS="
set "PICKABLE="
set "AUTO="
set "OTHERS="
set "NPICK=0"
set "NAUTO=0"

rem the install media: a volume with \sources\boot.wim (X: is WinPE's RAM disk)
set "MEDIA="
if defined TEST (
  set "MEDIA=%DP_TEST_MEDIA%"
) else (
  for %%L in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do (
    if exist "%%L:\sources\boot.wim" set "MEDIA=!MEDIA! %%L"
  )
)
call :log media volume(s): %MEDIA%

echo   Looking for disks...
if defined TEST (
  copy /y "%DP_TEST_DIR%\list.txt" "%WORK%\list.txt" >nul
) else (
  > "%WORK%\list-disk.txt" echo list disk
  diskpart /s "%WORK%\list-disk.txt" > "%WORK%\list.txt" 2>&1
)
rem "  Disk 0    Online          100 GB      0 B        *"
for /f "usebackq tokens=1,2,*" %%a in ("%WORK%\list.txt") do (
  if "%%a"=="Disk" call :addDisk %%b %%c
)

rem one diskpart run per disk: a script stops at the first error (e.g. a card
rem reader with no card), which would lose the details of the disks after it
for %%n in (%DISKS%) do (
  if defined TEST (
    copy /y "%DP_TEST_DIR%\detail-%%n.txt" "%WORK%\detail-%%n.txt" >nul 2>&1
  ) else (
    > "%WORK%\detail-disk.txt" (
      echo select disk %%n
      echo detail disk
      echo list partition
    )
    diskpart /s "%WORK%\detail-disk.txt" > "%WORK%\detail-%%n.txt" 2>&1
  )
  call :readDetail %%n
  call :classify %%n
)
call :log disks:%DISKS%; pickable:%PICKABLE%; automatic:%AUTO%; other:%OTHERS%
goto :eof

rem :addDisk <n> <rest of the list disk line>: size is the first "<number> <unit>"
rem (the status can be two words, e.g. "No Media")
:addDisk
set "n=%~1"
call :isNumber "%n%" || goto :eof
set "DISKS=%DISKS% %n%"
set "D_%n%_GB=0"
set "D_%n%_SIZE=?"
:addDisk_next
shift
if "%~1"=="" goto :eof
call :isNumber "%~1" || goto :addDisk_next
for %%u in (B KB MB GB TB PB) do if /i "%~2"=="%%u" goto :addDisk_size
goto :addDisk_next
:addDisk_size
set "D_%n%_SIZE=%~1 %~2"
rem diskpart's GB are GiB
if /i "%~2"=="GB" set /a "D_%n%_GB=%~1"
if /i "%~2"=="TB" set /a "D_%n%_GB=%~1 * 1024"
if /i "%~2"=="PB" set /a "D_%n%_GB=%~1 * 1048576"
goto :eof

:isNumber
set "_num=%~1"
if not defined _num exit /b 1
for /f "delims=0123456789" %%x in ("%_num%") do exit /b 1
exit /b 0

rem :readDetail <n>: model, bus type, status, read-only, partitions and volumes
rem from detail-<n>.txt ("detail disk" + "list partition")
:readDetail
set "n=%~1"
set "D_%n%_MODEL=(unknown model)"
set "D_%n%_TYPE=?"
set "D_%n%_STATUS=?"
set "D_%n%_RO=No"
set "D_%n%_NP=0"
set "D_%n%_NV=0"
set "_m=0"
if not exist "%WORK%\detail-%n%.txt" goto :eof
for /f "usebackq delims=" %%L in ("%WORK%\detail-%n%.txt") do (
  set "line=%%L"
  rem the model is the line after "Disk N is now the selected disk."
  if "!_m!"=="1" (
    set "D_%n%_MODEL=%%L"
    set "_m=2"
  )
  if "!line:~0,5!"=="Disk " if not "!line:now the selected disk=!"=="!line!" set "_m=1"
  if "!line:~0,9!"=="Type   : " set "D_%n%_TYPE=!line:~9!"
  if "!line:~0,9!"=="Status : " set "D_%n%_STATUS=!line:~9!"
  if "!line:~0,26!"=="Current Read-only State : " set "D_%n%_RO=!line:~26!"
  if "!line:~0,12!"=="  Partition " if not "!line:~12,3!"=="###" set /a "D_%n%_NP+=1"
  if "!line:~0,9!"=="  Volume " if not "!line:~9,3!"=="###" call :addVolume %n%
)
call :trim D_%n%_MODEL
call :trim D_%n%_TYPE
call :trim D_%n%_STATUS
call :trim D_%n%_RO
goto :eof

rem :addVolume <n>, line = "  Volume 3     C   Windows      NTFS   Partition     63 GB  Healthy    Boot"
rem (fixed columns: letter at 15, label 19-29, file system 32-36, size 51-57)
:addVolume
set /a "D_%1_NV+=1"
set "_k=!D_%1_NV!"
set "_v=!line:~15,1!:  !line:~19,11! !line:~32,5! !line:~51,7!"
if "!line:~15,1!"==" " set "_v=    !line:~19,11! !line:~32,5! !line:~51,7!"
set "D_%1_V!_k!=!_v!"
set "_l=!line:~15,1!"
if not "!_l!"==" " for %%m in (%MEDIA%) do if /i "%%m"=="!_l!" set "D_%1_MEDIA=1"
rem Ventoy keeps the ISO on its own partitions; never offer that disk
if not "!line: Ventoy =!"=="!line!" set "D_%1_MEDIA=1"
if not "!line:VTOYEFI=!"=="!line!" set "D_%1_MEDIA=1"
goto :eof

:classify
set "_why="
for %%t in (USB SD MMC 1394) do if /i "!D_%1_TYPE!"=="%%t" set "_why=removable (!D_%1_TYPE!)"
if /i "!D_%1_TYPE!"=="File Backed Virtual" set "_why=virtual disk file"
if /i "!D_%1_STATUS!"=="No Media" set "_why=no media"
if defined D_%1_MEDIA set "_why=holds the install media"
if defined _why (
  set "D_%1_WHY=!_why!"
  set "OTHERS=!OTHERS! %1"
  goto :eof
)
set "PICKABLE=!PICKABLE! %1"
set /a NPICK+=1
if !D_%1_GB! GEQ %DP_MIN_GB% (
  set "AUTO=!AUTO! %1"
  set /a NAUTO+=1
) else (
  set "D_%1_NOTE=smaller than %DP_MIN_GB% GB"
)
goto :eof

:showDisk
set "_c1=%1      "
set "_c2=!D_%1_SIZE!          "
set "_c3=!D_%1_TYPE!        "
echo     !_c1:~0,4!  !_c2:~0,8!  !_c3:~0,6!  !D_%1_MODEL:~0,42!
set "_note=!D_%1_NP! partition(s)"
if not "!D_%1_STATUS!"=="Online" set "_note=!_note!, !D_%1_STATUS!"
if /i "!D_%1_RO!"=="Yes" set "_note=!_note!, read-only"
if defined D_%1_NOTE set "_note=!_note!, !D_%1_NOTE!"
echo                                 !_note!
set "_nv=!D_%1_NV!"
for /l %%k in (1,1,%_nv%) do echo                                   !D_%1_V%%k!
echo(
goto :eof

:showOther
set "_c1=%1      "
set "_c2=!D_%1_SIZE!          "
set "_c3=!D_%1_TYPE!        "
echo     !_c1:~0,4!  !_c2:~0,8!  !_c3:~0,6!  !D_%1_MODEL:~0,30!: !D_%1_WHY!
goto :eof

rem in tests stdin is a file of answers; a real pause would eat one
:pause
if defined TEST (echo [test] pause) else pause
goto :eof

rem :trim <variable>: drop trailing spaces
:trim
if not defined %~1 goto :eof
if "!%~1:~-1!"==" " (
  set "%~1=!%~1:~0,-1!"
  goto :trim
)
goto :eof
