@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem =========================================================
rem Bonsai-8B Server Script (Windows)
rem Prism-only build source (CPU + CUDA)
rem =========================================================

rem -------------------------
rem Base paths
rem -------------------------
set "SCRIPT_DIR=%~dp0"
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

rem -------------------------
rem User-overridable settings
rem -------------------------
if not defined HF_TOKEN set "HF_TOKEN="
if not defined MODEL_DIR set "MODEL_DIR=%SCRIPT_DIR%\models"
if not defined MODEL_FILE set "MODEL_FILE=Bonsai-8B.gguf"
if not defined MODEL_PATH set "MODEL_PATH=%MODEL_DIR%\%MODEL_FILE%"
if not defined HF_MODEL_URL set "HF_MODEL_URL=https://huggingface.co/prism-ml/Bonsai-8B-gguf/resolve/main/Bonsai-8B.gguf"

if not defined PORT set "PORT=8002"
if not defined HOST set "HOST=0.0.0.0"
if not defined CONTEXT_SIZE set "CONTEXT_SIZE=4096"

rem GPU offload layer count when GPU is active
if not defined GPU_LAYERS set "GPU_LAYERS=99"

rem Set FORCE_CPU=1 to disable GPU usage even if NVIDIA exists
if not defined FORCE_CPU set "FORCE_CPU=0"

rem Optional custom binary dirs
if not defined CPU_BIN_DIR set "CPU_BIN_DIR=%SCRIPT_DIR%\bin\cpu"
if not defined CUDA_BIN_DIR set "CUDA_BIN_DIR=%SCRIPT_DIR%\bin\cuda"

rem -------------------------
rem Prism release assets
rem IMPORTANT:
rem CPU and CUDA now BOTH come only from PrismML-Eng/llama.cpp
rem Override these names from environment if release asset names change
rem -------------------------
if not defined PRISM_RELEASE_TAG set "PRISM_RELEASE_TAG=prism-b8194-1179bfc"
if not defined PRISM_RELEASE_BASE_URL set "PRISM_RELEASE_BASE_URL=https://github.com/PrismML-Eng/llama.cpp/releases/download/%PRISM_RELEASE_TAG%"

rem CUDA assets
if not defined PRISM_CUDA_ZIP set "PRISM_CUDA_ZIP=llama-prism-b1-1179bfc-bin-win-cuda-12.4-x64.zip"
if not defined PRISM_CUDART_ZIP set "PRISM_CUDART_ZIP=cudart-llama-bin-win-cuda-12.4-x64.zip"

rem CPU asset from the SAME Prism release
rem You may override this if the exact asset name differs in that release
if not defined PRISM_CPU_ZIP set "PRISM_CPU_ZIP=llama-prism-b1-1179bfc-bin-win-cpu-x64.zip"

rem -------------------------
rem Runtime state
rem -------------------------
set "GPU_AVAILABLE=0"
set "RUN_MODE=CPU"
set "BIN_DIR="
set "LLAMA_SERVER="
set "TOTAL_VRAM=0"

echo ========================================================
echo Bonsai-8B Server Launcher
echo ========================================================
echo Script dir    : %SCRIPT_DIR%
echo Model path    : %MODEL_PATH%
echo Model URL     : %HF_MODEL_URL%
echo Prism release : %PRISM_RELEASE_TAG%
echo Host          : %HOST%
echo Port          : %PORT%
echo Context       : %CONTEXT_SIZE%
echo Force CPU     : %FORCE_CPU%
echo.

if not exist "%MODEL_DIR%" mkdir "%MODEL_DIR%"
if not exist "%CPU_BIN_DIR%" mkdir "%CPU_BIN_DIR%"
if not exist "%CUDA_BIN_DIR%" mkdir "%CUDA_BIN_DIR%"

rem =========================================================
rem Detect GPU unless FORCE_CPU=1
rem =========================================================
if "%FORCE_CPU%"=="1" (
    echo FORCE_CPU=1 -> GPU detection skipped. CPU mode will be used.
    goto :set_cpu_mode
)

echo Checking NVIDIA GPU availability...
where nvidia-smi >nul 2>&1
if errorlevel 1 (
    echo nvidia-smi not found. CPU mode will be used.
    goto :set_cpu_mode
)

nvidia-smi >nul 2>&1
if errorlevel 1 (
    echo nvidia-smi is not accessible. CPU mode will be used.
    goto :set_cpu_mode
)

set "GPU_AVAILABLE=1"
set "RUN_MODE=CUDA"

echo NVIDIA GPU detected:
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader

for /f "tokens=* delims=" %%i in ('nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2^>nul') do (
    set "TOTAL_VRAM_RAW=%%i"
    goto :got_vram
)

:got_vram
if defined TOTAL_VRAM_RAW (
    for /f "tokens=1" %%i in ("%TOTAL_VRAM_RAW%") do set "TOTAL_VRAM=%%i"
) else (
    set "TOTAL_VRAM=0"
)

echo Total VRAM    : %TOTAL_VRAM% MB

if "%TOTAL_VRAM%"=="0" (
    echo Could not determine VRAM cleanly. Falling back to CPU mode.
    goto :set_cpu_mode
)

if %TOTAL_VRAM% LSS 1024 (
    echo VRAM is below 1024 MB. Falling back to CPU mode.
    goto :set_cpu_mode
)

goto :mode_selected

:set_cpu_mode
set "GPU_AVAILABLE=0"
set "RUN_MODE=CPU"

:mode_selected
echo.
echo Selected mode : %RUN_MODE%
echo.

rem =========================================================
rem Assign binary location
rem =========================================================
if "%RUN_MODE%"=="CUDA" (
    set "BIN_DIR=%CUDA_BIN_DIR%"
) else (
    set "BIN_DIR=%CPU_BIN_DIR%"
)

set "LLAMA_SERVER=%BIN_DIR%\llama-server.exe"

echo Binary dir    : %BIN_DIR%
echo Server exe    : %LLAMA_SERVER%
echo.

rem =========================================================
rem Ensure llama-server exists
rem =========================================================
if exist "%LLAMA_SERVER%" goto :model_check

echo llama-server.exe not found. Downloading binaries...
echo.

if "%RUN_MODE%"=="CUDA" goto :try_cuda

:do_cpu
call :download_cpu_binary
if errorlevel 1 goto :binary_download_failed
if not exist "%LLAMA_SERVER%" goto :binary_download_failed
goto :model_check

:try_cuda
call :download_cuda_binary
if errorlevel 1 (
    echo CUDA binary setup failed. Falling back to CPU mode...
    set "GPU_AVAILABLE=0"
    set "RUN_MODE=CPU"
    set "BIN_DIR=%CPU_BIN_DIR%"
    set "LLAMA_SERVER=%BIN_DIR%\llama-server.exe"
    goto :do_cpu
)
goto :model_check

:binary_download_failed
echo ERROR: Failed to prepare llama-server binary.
exit /b 1

rem =========================================================
rem Download model if missing
rem =========================================================
:model_check
if exist "%MODEL_PATH%" goto :verify_model

echo Model not found locally.
echo Downloading model to:
echo   %MODEL_PATH%
echo.

call :download_model
if errorlevel 1 (
    echo ERROR: Model download failed.
    exit /b 1
)

echo Model download completed.
echo.

:verify_model
if not exist "%MODEL_PATH%" (
    echo ERROR: Model file not found at:
    echo   %MODEL_PATH%
    exit /b 1
)

rem =========================================================
rem Final launch parameters
rem =========================================================
if "%RUN_MODE%"=="CUDA" (
    set "FINAL_GPU_LAYERS=%GPU_LAYERS%"
) else (
    set "FINAL_GPU_LAYERS=0"
)

echo ========================================================
echo Launch configuration
echo ========================================================
echo Mode          : %RUN_MODE%
echo Model         : %MODEL_PATH%
echo Host          : %HOST%
echo Port          : %PORT%
echo Context       : %CONTEXT_SIZE%
echo GPU layers    : %FINAL_GPU_LAYERS%
echo Binary        : %LLAMA_SERVER%
echo ========================================================
echo.

if not exist "%LLAMA_SERVER%" (
    echo ERROR: llama-server binary not found at:
    echo   %LLAMA_SERVER%
    exit /b 1
)

"%LLAMA_SERVER%" ^
    -m "%MODEL_PATH%" ^
    --host %HOST% ^
    --port %PORT% ^
    -c %CONTEXT_SIZE% ^
    -ngl %FINAL_GPU_LAYERS% ^
    -fa on ^
    --jinja ^
    --metrics ^
    --alias "Bonsai-8B"

exit /b %errorlevel%

rem =========================================================
rem Functions
rem =========================================================

:download_cuda_binary
setlocal EnableDelayedExpansion
set "DOWNLOAD_URL=%PRISM_RELEASE_BASE_URL%"
set "ZIP_LLAMA=%PRISM_CUDA_ZIP%"
set "ZIP_CUDART=%PRISM_CUDART_ZIP%"

echo [CUDA] Download URL : !DOWNLOAD_URL!
echo [CUDA] Main zip     : !ZIP_LLAMA!
echo [CUDA] CUDART zip   : !ZIP_CUDART!
echo.

call :require_curl
if errorlevel 1 (
    echo [CUDA] curl is required for binary download.
    endlocal & exit /b 1
)

curl -L --fail -o "%TEMP%\llama_cuda.zip" "!DOWNLOAD_URL!/!ZIP_LLAMA!"
if errorlevel 1 (
    echo [CUDA] Failed to download main CUDA zip.
    endlocal & exit /b 1
)

powershell -NoProfile -Command "Expand-Archive -Path '%TEMP%\llama_cuda.zip' -DestinationPath '%CUDA_BIN_DIR%' -Force"
if errorlevel 1 (
    del /q "%TEMP%\llama_cuda.zip" 2>nul
    echo [CUDA] Failed to extract main CUDA zip.
    endlocal & exit /b 1
)

del /q "%TEMP%\llama_cuda.zip" 2>nul

call :normalize_binary_layout "%CUDA_BIN_DIR%"
if errorlevel 1 (
    echo [CUDA] Could not normalize extracted files.
    endlocal & exit /b 1
)

if not exist "%CUDA_BIN_DIR%\llama-server.exe" (
    echo [CUDA] llama-server.exe still missing after extraction.
    endlocal & exit /b 1
)

if not "!ZIP_CUDART!"=="" (
    curl -L --fail -o "%TEMP%\llama_cudart.zip" "!DOWNLOAD_URL!/!ZIP_CUDART!"
    if not errorlevel 1 (
        powershell -NoProfile -Command "Expand-Archive -Path '%TEMP%\llama_cudart.zip' -DestinationPath '%CUDA_BIN_DIR%' -Force"
        del /q "%TEMP%\llama_cudart.zip" 2>nul
        call :normalize_binary_layout "%CUDA_BIN_DIR%" >nul 2>&1
    )
)

echo [CUDA] Binary setup completed.
endlocal & exit /b 0

:download_cpu_binary
setlocal EnableDelayedExpansion
set "DOWNLOAD_URL=%PRISM_RELEASE_BASE_URL%"
set "ZIP_LLAMA=%PRISM_CPU_ZIP%"

echo [CPU] Download URL  : !DOWNLOAD_URL!
echo [CPU] Main zip      : !ZIP_LLAMA!
echo.

call :require_curl
if errorlevel 1 (
    echo [CPU] curl is required for binary download.
    endlocal & exit /b 1
)

curl -L --fail -o "%TEMP%\llama_cpu.zip" "!DOWNLOAD_URL!/!ZIP_LLAMA!"
if errorlevel 1 (
    echo [CPU] Failed to download CPU zip.
    echo [CPU] Check PRISM_CPU_ZIP value for this release.
    endlocal & exit /b 1
)

powershell -NoProfile -Command "Expand-Archive -Path '%TEMP%\llama_cpu.zip' -DestinationPath '%CPU_BIN_DIR%' -Force"
if errorlevel 1 (
    del /q "%TEMP%\llama_cpu.zip" 2>nul
    echo [CPU] Failed to extract CPU zip.
    endlocal & exit /b 1
)

del /q "%TEMP%\llama_cpu.zip" 2>nul

call :normalize_binary_layout "%CPU_BIN_DIR%"
if errorlevel 1 (
    echo [CPU] Could not normalize extracted files.
    endlocal & exit /b 1
)

if not exist "%CPU_BIN_DIR%\llama-server.exe" (
    echo [CPU] llama-server.exe still missing after extraction.
    endlocal & exit /b 1
)

echo [CPU] Binary setup completed.
endlocal & exit /b 0

:normalize_binary_layout
setlocal
set "TARGET_DIR=%~1"

if exist "%TARGET_DIR%\llama-server.exe" (
    endlocal & exit /b 0
)

if exist "%TARGET_DIR%\bin\llama-server.exe" (
    for %%F in ("%TARGET_DIR%\bin\*") do (
        move /Y "%%~fF" "%TARGET_DIR%\" >nul 2>&1
    )
    rd /q /s "%TARGET_DIR%\bin" 2>nul
)

if exist "%TARGET_DIR%\llama-server.exe" (
    endlocal & exit /b 0
)

for /d %%D in ("%TARGET_DIR%\*") do (
    if exist "%%~fD\llama-server.exe" (
        for %%F in ("%%~fD\*") do (
            move /Y "%%~fF" "%TARGET_DIR%\" >nul 2>&1
        )
        rd /q /s "%%~fD" 2>nul
        goto :normalize_done
    )
    if exist "%%~fD\bin\llama-server.exe" (
        for %%F in ("%%~fD\bin\*") do (
            move /Y "%%~fF" "%TARGET_DIR%\" >nul 2>&1
        )
        rd /q /s "%%~fD" 2>nul
        goto :normalize_done
    )
)

:normalize_done
if exist "%TARGET_DIR%\llama-server.exe" (
    endlocal & exit /b 0
)

endlocal & exit /b 1

:download_model
setlocal

where curl >nul 2>&1
if not errorlevel 1 goto :model_with_curl

where powershell >nul 2>&1
if not errorlevel 1 goto :model_with_powershell

echo No supported download tool found.
endlocal & exit /b 1

:model_with_curl
echo Using curl to download model...
if defined HF_TOKEN if not "%HF_TOKEN%"=="" (
    curl -L -C - --fail -H "Authorization: Bearer %HF_TOKEN%" -o "%MODEL_PATH%" "%HF_MODEL_URL%"
) else (
    curl -L -C - --fail -o "%MODEL_PATH%" "%HF_MODEL_URL%"
)
if errorlevel 1 (
    endlocal & exit /b 1
)
endlocal & exit /b 0

:model_with_powershell
echo Using PowerShell to download model...
if defined HF_TOKEN if not "%HF_TOKEN%"=="" (
    powershell -NoProfile -Command ^
        "$headers = @{ Authorization = 'Bearer %HF_TOKEN%' }; Invoke-WebRequest -Headers $headers -Uri '%HF_MODEL_URL%' -OutFile '%MODEL_PATH%'"
) else (
    powershell -NoProfile -Command ^
        "Invoke-WebRequest -Uri '%HF_MODEL_URL%' -OutFile '%MODEL_PATH%'"
)
if errorlevel 1 (
    endlocal & exit /b 1
)
endlocal & exit /b 0

:require_curl
where curl >nul 2>&1
if not errorlevel 1 exit /b 0

curl.exe --version >nul 2>&1
if not errorlevel 1 exit /b 0

exit /b 1