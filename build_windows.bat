@echo off
rem ===========================================================================
rem build_windows.bat -- build phcp.exe and phcp_editor.exe on a Windows PC.
rem
rem Copyright (c) 2026 Hycadia Pty Ltd.  SPDX-License-Identifier: MIT
rem
rem The command-line program, phcp.exe, needs nothing beyond Strawberry Perl
rem and is always built.  The text editor, phcp_editor.exe, also needs Tk,
rem which has to be COMPILED here from source -- and that is the step that can
rem fail.  So the two are built independently: if Tk will
rem not build, you still get a working phcp.exe, and the Tk build log is copied
rem to tk_build.log in this folder so the cause can be read.
rem
rem WHY TK NEEDS A PATCHED RELEASE
rem   Tk 804.036 on CPAN does not compile with recent Strawberry Perl
rem   toolchains: a definition in Tk's copy of the X11 headers, X.h, clashes
rem   with one in the Windows headers ("expected identifier or '(' before
rem   numeric constant" at ControlMask).  The Strawberry Perl maintainers
rem   publish a patched release, Tk 804.036_001, with that header fixed, and
rem   it is installed from their GitHub release below.  An older Perl does not
rem   avoid the problem -- it is reported on 5.38 as well.
rem
rem   One Tk self-test, for $widget->pathname, is known to fail with the
rem   patched release on new Perls.  PHCP does not use pathname, so the tests
rem   are skipped (--notest) and PHCP is tested instead by opening it.
rem
rem BEFORE RUNNING
rem   Strawberry Perl, 64-bit, installed from https://strawberryperl.com
rem   Then, in a new Command Prompt or PowerShell in this folder:
rem       .\build_windows.bat
rem ===========================================================================

setlocal EnableDelayedExpansion
cd /d "%~dp0"

rem This script builds the program files that sit BESIDE it.  Run on its own,
rem copied out of the package, it has nothing to build -- so it says so plainly
rem instead of failing later with a packager error about a missing file.
if not exist phcp.pl goto :notinpackage
if not exist HardyCross\PipeData.pm goto :notinpackage
if not exist data\pipes.dat goto :notinpackage
set TKPATCHED=https://github.com/StrawberryPerl/Perl-Dist-Strawberry/releases/download/patched_cpan_modules/Tk-804.036_001.tar.gz
set GUI=yes

echo.
echo [1/6] Checking Strawberry Perl...
where perl >nul 2>&1 || (echo ERROR: perl not found. Install Strawberry Perl first. & exit /b 1)
for /f "tokens=*" %%v in ('perl -e "printf qq{%%vd}, $^V"') do set PERLV=%%v
for /f "tokens=*" %%g in ('gcc -dumpversion 2^>nul') do set GCCV=%%g
echo        Perl !PERLV!, GCC !GCCV!

echo.
echo [2/6] PAR::Packer (the packager)...
perl -MPAR::Packer -e1 >nul 2>&1 || call cpanm --notest PAR::Packer
perl -MPAR::Packer -e1 >nul 2>&1 || (echo ERROR: PAR::Packer is not available. & exit /b 1)
echo        ok

echo.
echo [3/6] Tk (needed only for the text editor)...
perl -MTk -e1 >nul 2>&1
if errorlevel 1 (
    echo        Installing the patched Tk 804.036_001 from the Strawberry Perl project...
    call cpanm --notest %TKPATCHED%
)
perl -MTk -e1 >nul 2>&1
if errorlevel 1 (
    set GUI=no
    call :savelog tk_build.log
)

rem Win32::API lets the editor tell Windows it draws itself at the screen's
rem real resolution, so it is sharp at 125 or 150 per cent scaling instead of
rem stretched and soft.  Strawberry Perl normally includes it.  Without it
rem the editor still runs, only blurred on a scaled display.
set DPI=
perl -MWin32::API -e1 >nul 2>&1 || call cpanm --notest Win32::API
perl -MWin32::API -e1 >nul 2>&1 && set DPI=-M Win32::API

rem The program icon: the editor sets it on its own window and taskbar
rem button when it runs.  PAR::Packer no longer writes an icon into an .exe
rem (its --icon option was removed), so the .exe files themselves show the
rem default icon in Explorer.

rem HardyCross::Phc is loaded with require only when a .phc file is read,
rem so it is listed here by name rather than left to the dependency scan.
set MODS=-M HardyCross -M HardyCross::Parse -M HardyCross::PipeData -M HardyCross::Report -M HardyCross::Demand -M HardyCross::PDF -M HardyCross::Phc -M HardyCross::Settings -M HardyCross::Json -M JSON::PP
rem The database goes to lib\data inside the package, which is where
rem HardyCross::PipeData looks for it when running from a packaged .exe.
rem The PDF report's typeface goes beside it, in lib\data\fonts.
set DATA=-a "data/pipes.dat;lib/data/pipes.dat" -a "data/fonts;lib/data/fonts"

echo.
echo [4/6] Building phcp.exe (command line)...
call pp -I . %MODS% %DATA% -o phcp.exe phcp.pl
if errorlevel 1 (echo ERROR: pp failed building phcp.exe & exit /b 1)

echo.
echo [5/6] Building phcp_editor.exe (text editor)...
if "!GUI!"=="yes" (
    call pp --gui -I . %MODS% -M HardyCross::Editor -M HardyCross::DbEdit -M HardyCross::Graph -M HardyCross::Tools -M Tk -M Tk::DirTree -M Tk::TextUndo -M Tk::Panedwindow -M Tk::HList -M Tk::ItemStyle -M Tk::Menubutton -M Tk::Entry -M Tk::Listbox -M Tk::Menu -M Tk::Text -M Tk::Scrollbar -M Tk::Canvas -M Tk::PNG !DPI! %DATA% -o phcp_editor.exe phcp_editor.pl
    if errorlevel 1 (echo ERROR: pp failed building phcp_editor.exe & set GUI=no)
) else (
    echo        SKIPPED - Tk could not be built.  See the note at the end.
)

echo.
echo [6/6] Smoke test: solve an example with phcp.exe...
phcp.exe examples\05_crosscheck.phc > smoke_test_phc.txt
findstr /c:"converged yes" smoke_test_phc.txt >nul || (echo ERROR: phcp.exe did not solve the .phc example. See smoke_test_phc.txt & exit /b 1)
phcp.exe examples\07_pipe_database_demo.phc smoke_test.pdf >nul
if not exist smoke_test.pdf (echo ERROR: no PDF was written & exit /b 1)
phcp.exe --json examples\05_crosscheck.phc > smoke_test.json
findstr /c:"\"interface\" : 1" smoke_test.json >nul || (echo ERROR: phcp.exe --json gave no result. See smoke_test.json & exit /b 1)
echo        ok - .phc examples solved and converged, PDF report and JSON written

echo.
echo ===========================================================================
if "!GUI!"=="yes" (
    echo  Built: phcp.exe and phcp_editor.exe
) else (
    echo  Built: phcp.exe  ^(command line, working^)
    echo  NOT built: phcp_editor.exe - Tk would not compile with Perl !PERLV! / GCC !GCCV!
    echo  The compiler output is saved in this folder as tk_build.log.
    echo  Send the last 40 lines of it for diagnosis.
)
echo ===========================================================================
endlocal
exit /b 0

rem ---------------------------------------------------------------------------
:notinpackage
echo.
echo ERROR: this folder does not contain the PHCP program files.
echo        build_windows.bat must be run from INSIDE the extracted phcp folder:
echo          1. extract phcp.zip
echo          2. open the phcp folder it creates ^(phcp.pl, HardyCross, data, examples^)
echo          3. run .\build_windows.bat there
echo        Currently in: %CD%
exit /b 1

rem ---------------------------------------------------------------------------
rem Copy the most recent cpanm build log into this folder under the given name.
rem cpanm keeps one work folder per run; the newest is the one that failed.
:savelog
for /f "delims=" %%d in ('dir /b /ad /o-d "%USERPROFILE%\.cpanm\work" 2^>nul') do (
    if exist "%USERPROFILE%\.cpanm\work\%%d\build.log" (
        copy /y "%USERPROFILE%\.cpanm\work\%%d\build.log" "%~1" >nul
        goto :eof
    )
)
goto :eof
