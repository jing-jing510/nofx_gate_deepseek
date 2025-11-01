@echo off
chcp 65001 >nul
echo ═══════════════════════════════════════════════════════════════
echo    NOFX AI Trading System - Windows 编译脚本
echo ═══════════════════════════════════════════════════════════════
echo.

set GOPROXY=https://goproxy.cn,direct
set GO111MODULE=on

echo [1/3] 检查环境...
where go >nul 2>&1
if %errorlevel% neq 0 (
    echo ❌ 错误: 未找到 Go，请先安装 Go 1.25.0 或更高版本
    pause
    exit /b 1
)

where node >nul 2>&1
if %errorlevel% neq 0 (
    echo ❌ 错误: 未找到 Node.js，请先安装 Node.js
    pause
    exit /b 1
)

where npm >nul 2>&1
if %errorlevel% neq 0 (
    echo ❌ 错误: 未找到 npm，请先安装 npm
    pause
    exit /b 1
)

go version
node --version
npm --version
echo.

echo [2/3] 编译后端...
go mod tidy
if %errorlevel% neq 0 (
    echo ❌ Go依赖整理失败
    pause
    exit /b 1
)

go build -o nofx.exe .
if %errorlevel% neq 0 (
    echo ❌ 后端编译失败
    pause
    exit /b 1
)

if exist nofx.exe (
    echo ✓ 后端编译成功: nofx.exe
) else (
    echo ❌ 后端编译失败: 未找到 nofx.exe
    pause
    exit /b 1
)
echo.

echo [3/3] 编译前端...
cd web

echo 配置 npm 使用国内镜像...
call npm config set registry https://registry.npmmirror.com

echo 安装前端依赖...
call npm install
if %errorlevel% neq 0 (
    echo ❌ 前端依赖安装失败
    cd ..
    pause
    exit /b 1
)

echo 编译前端...
call npm run build
if %errorlevel% neq 0 (
    echo ❌ 前端编译失败
    cd ..
    pause
    exit /b 1
)

cd ..

if exist web\dist (
    echo ✓ 前端编译成功: web\dist
) else (
    echo ❌ 前端编译失败: 未找到 web\dist
    pause
    exit /b 1
)
echo.

echo ═══════════════════════════════════════════════════════════════
echo    ✓ 编译完成！
echo ═══════════════════════════════════════════════════════════════
echo.
echo 生成的文件:
echo   - nofx.exe (后端可执行文件)
echo   - web\dist\ (前端静态文件)
echo.
pause

