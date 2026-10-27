@echo off
setlocal
cd /d "%~dp0"

:: Check for admin privileges
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting administrative privileges...
    :: Relaunch the batch file with admin rights
    PowerShell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

:: Check if device is already in recovery mode
for /f "tokens=1,2" %%i in ('"%~dp0bin\adb.exe" devices') do (
    if "%%i" NEQ "List" (
        if "%%j"=="recovery" (
            echo ADB device already in recovery mode: %%i
            choice /C YN /M "Skip EFIESP copy and continue directly from recovery"
            if errorlevel 2 goto select_efiesp
            goto insiderecovery
        )
    )
)

:select_efiesp
:: Prompt for EFIESP directory
set "psCommand="(new-object -COM 'Shell.Application').BrowseForFolder(0,'Select EFIESP directory.',0,0).self.path""

for /f "usebackq delims=" %%I in (`PowerShell -NoProfile -Command %psCommand%`) do set "efiesp_location=%%I"

if "%efiesp_location%"=="" (
    echo No EFIESP directory selected. Exiting.
    pause
    exit /b 1
)

REM Define paths
set "bcd_file=%efiesp_location%\EFI\Microsoft\BOOT\BCD"
set "bootmgr_efisp_location=%efiesp_location%\Windows\System32\BOOT"

REM Check if BCD file exists
IF NOT EXIST "%bcd_file%" (
    echo "BCD file not found at %bcd_file% make sure it's the right path"
    pause
    exit /b 1
)

echo Replacing BCD
copy /y "%~dp0DATA\BCD" "%bcd_file%" >nul 2>&1

echo Copying bootshim
copy /y "%~dp0DATA\bootshim.efi" "%bootmgr_efisp_location%" >nul 2>&1

copy /y "%~dp0DATA\Stage2.efi" "%efiesp_location%" >nul 2>&1


echo Copying developermenu
copy /y "%~dp0DATA\developermenu.efi" "%bootmgr_efisp_location%" >nul 2>&1

if not exist "%bootmgr_efisp_location%\ui" (
    md "%bootmgr_efisp_location%\ui" >nul 2>&1
    IF ERRORLEVEL 1 (
        echo Failed to create ui directory
        pause
        exit /b 1
    )
)
copy /y "%~dp0ui\*.bmpx" "%bootmgr_efisp_location%\ui\" >nul 2>&1


echo Copying LK2ND
copy /y "%~dp0DATA\emmc_appsboot.mbn" "%efiesp_location%" >nul 2>&1

echo Done! Reboot your phone and you should be prompted to LK2ND!
pause

echo Booting recovery

"%~dp0bin\fastboot.exe" boot "%~dp0DATA\twrp.img"

:waitforadb
echo Waiting for device in recovery mode...
timeout /t 10 /nobreak >nul
for /f "tokens=1,2" %%i in ('"%~dp0bin\adb.exe" devices') do (
    if "%%i" NEQ "List" (
        if "%%j"=="recovery" (
            echo ADB device connected in recovery: %%i
            goto insiderecovery
        )
        if "%%j"=="device" (
            echo ADB device connected: %%i
            goto insiderecovery
        )
    )
)
goto waitforadb

:insiderecovery
REM Wait a few seconds for TWRP USB/MTP initialization to settle
timeout /t 5 /nobreak >nul
echo Copying partition script
"%~dp0bin\adb.exe" push "%~dp0partition.sh" / >nul 2>&1
IF ERRORLEVEL 1 (
    echo Failed to push partition.sh
    pause
    exit /b 1
)

echo Running partition script
"%~dp0bin\adb.exe" shell "sed -i 's/\r$//' /partition.sh && bash /partition.sh"
IF ERRORLEVEL 1 (
    echo Failed to run partition.sh
    pause
    exit /b 1
)

for /f "usebackq delims=" %%i in (`PowerShell -NoProfile -Command "Get-Date -Format 'dd.MM.yyyy_HHmm'"`) do set "current_date=-%%i"

rem Create the backup folder with the current date
set "backup_folder=%~dp0backup%current_date%"

echo Pulling backup
"%~dp0bin\adb.exe" pull /backup "%backup_folder%" >nul 2>&1

echo Rebooting to bootloader
"%~dp0bin\adb.exe" reboot bootloader

REM Flashing recovery and modem images
"%~dp0bin\fastboot.exe" flash recovery "%~dp0DATA\twrp.img"

"%~dp0bin\fastboot.exe" flash modem "%~dp0DATA\modem.img"

echo Booting recovery
"%~dp0bin\fastboot.exe" boot "%~dp0DATA\twrp.img"

:waitforadb2
echo Waiting for device in recovery mode...
timeout /t 10 /nobreak >nul
for /f "tokens=1,2" %%i in ('"%~dp0bin\adb.exe" devices') do (
    if "%%i" NEQ "List" (
        if "%%j"=="recovery" (
            echo ADB device connected in recovery: %%i
            goto insideprovision
        )
        if "%%j"=="device" (
            echo ADB device connected: %%i
            goto insideprovision
        )
    )
)
goto waitforadb2

:insideprovision
REM Wait 5 seconds for TWRP recovery startup and MTP USB re-enumeration to finish
timeout /t 5 /nobreak >nul
echo Copying provisioning script
"%~dp0bin\adb.exe" push "%~dp0provision.sh" / >nul 2>&1
IF ERRORLEVEL 1 (
    echo Failed to push provision.sh
    pause
    exit /b 1
)

echo Running provisioning script
"%~dp0bin\adb.exe" shell "sed -i 's/\r$//' /provision.sh && bash /provision.sh"
IF ERRORLEVEL 1 (
    echo Failed to run provision.sh
    pause
    exit /b 1
)

echo Sideload an Android ROM then press any key.
pause

"%~dp0bin\adb.exe" reboot

echo Booting Android...
