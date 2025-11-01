@echo off
chcp 65001 >nul
echo ═══════════════════════════════════════════════════════════════
echo    NOFX AI Trading System - Windows 启动脚本
echo ═══════════════════════════════════════════════════════════════
echo.

REM 检查后端可执行文件
if not exist nofx.exe (
    echo ❌ 错误: 未找到 nofx.exe
    echo    请先运行 build.bat 编译项目
    pause
    exit /b 1
)

REM 检查前端目录
if not exist web (
    echo ❌ 错误: 未找到 web 目录
    pause
    exit /b 1
)

REM 检查前端依赖是否已安装
if not exist web\node_modules (
    echo ⚠ 警告: 前端依赖未安装，正在安装...
    cd web
    call npm install
    if %errorlevel% neq 0 (
        echo ❌ 前端依赖安装失败
        cd ..
        pause
        exit /b 1
    )
    cd ..
)

REM 检查配置文件
if not exist config.json (
    echo ❌ 错误: 未找到 config.json
    echo    请先复制 config.json.example 并配置
    pause
    exit /b 1
)

REM 设置端口（从配置文件读取，默认8080）
set API_PORT=8080
set FRONTEND_PORT=3000

echo [INFO] 启动参数:
echo   - 后端API端口: %API_PORT%
echo   - 前端端口: %FRONTEND_PORT%
echo   - 配置文件: config.json
echo.

REM 启动后端（在后台，输出日志到文件）
echo [1/2] 启动后端服务...
start "NOFX Backend" cmd /c "nofx.exe config.json > backend.log 2>&1"
timeout /t 2 /nobreak >nul

REM 检查后端是否启动成功
timeout /t 3 /nobreak >nul
curl -s http://localhost:%API_PORT%/health >nul 2>&1
if %errorlevel% neq 0 (
    echo ⚠ 警告: 后端可能未成功启动，请检查 backend.log
) else (
    echo ✓ 后端已启动: http://localhost:%API_PORT%
    echo   日志文件: backend.log
)

echo.

REM 启动前端（使用Vite开发服务器，支持API代理）
echo [2/2] 启动前端服务...

REM 检查是否有npm
where npm >nul 2>&1
if %errorlevel% neq 0 (
    echo ❌ 错误: 未找到 npm
    echo    请先安装 Node.js: https://nodejs.org/
    pause
    exit /b 1
)

echo 使用 Vite 开发服务器（支持API代理）...
cd web
start "NOFX Frontend" cmd /c "npm run dev > ..\frontend.log 2>&1"
cd ..
timeout /t 3 /nobreak >nul
echo ✓ 前端已启动: http://localhost:%FRONTEND_PORT%
echo   日志文件: frontend.log
echo.
echo ═══════════════════════════════════════════════════════════════
echo    ✓ 服务启动完成！
echo ═══════════════════════════════════════════════════════════════
echo.
echo 访问地址:
echo   - 前端界面: http://localhost:%FRONTEND_PORT%
echo   - API接口: http://localhost:%API_PORT%
echo.
echo 日志文件:
echo   - 后端日志: backend.log
echo   - 前端日志: frontend.log
echo.
echo 注意: 前端使用 Vite 开发服务器，会自动代理 /api 请求到后端
echo.
echo 按任意键停止服务...
pause >nul
REM 停止服务
echo.
echo 正在停止服务...
REM 停止前端（通过窗口标题）
taskkill /FI "WINDOWTITLE eq NOFX Frontend*" /F >nul 2>&1
REM 停止后端（通过窗口标题）
taskkill /FI "WINDOWTITLE eq NOFX Backend*" /F >nul 2>&1
REM 额外停止可能的 node 进程（Vite）
for /f "tokens=2" %%a in ('tasklist /FI "IMAGENAME eq node.exe" /FO LIST 2^>nul ^| findstr /C:"PID:"') do (
    taskkill /PID %%a /F >nul 2>&1
)
echo ✓ 服务已停止
exit /b 0

