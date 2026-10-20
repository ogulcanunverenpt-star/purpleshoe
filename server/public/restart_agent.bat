@echo off
set AGENT_PATH=C:\Temp\program_signed3.exe
set LOG_FILE=agent.log

:loop
if not exist "%AGENT_PATH%" (
    echo [%date% %time%] Agent executable not found: %AGENT_PATH% >> %LOG_FILE%
    timeout /t 5
    goto loop
)

echo [%date% %time%] Starting agent: %AGENT_PATH% >> %LOG_FILE%
start /b "" "%AGENT_PATH%"

:check
timeout /t 5
tasklist | findstr "program_signed3.exe" > nul
if errorlevel 1 (
    echo [%date% %time%] Agent stopped, restarting... >> %LOG_FILE%
    goto loop
)
goto check