@echo off
chcp 65001 >nul
echo ═══════════════════════════════════════════════════════════════
echo    NOFX AI Trading System - Windows 交叉编译 Linux 版本
echo ═══════════════════════════════════════════════════════════════
echo.

set GOPROXY=https://goproxy.cn,direct
set GO111MODULE=on

echo [1/3] 检查环境...
where go >nul 2>&1
if %errorlevel% neq 0 (
    echo ❌ 错误: 未找到 Go，请先安装 Go 1.21+ 或更高版本
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

echo [2/3] 交叉编译 Linux 后端...
go mod tidy
if %errorlevel% neq 0 (
    echo ❌ Go依赖整理失败
    pause
    exit /b 1
)

echo 设置交叉编译环境变量: GOOS=linux GOARCH=amd64
set GOOS=linux
set GOARCH=amd64

go build -o nofx-linux .
if %errorlevel% neq 0 (
    echo ❌ Linux 后端编译失败
    pause
    exit /b 1
)

if exist nofx-linux (
    echo ✓ Linux 后端编译成功: nofx-linux
) else (
    echo ❌ Linux 后端编译失败: 未找到 nofx-linux
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
echo 生成的文件（用于 Ubuntu/Linux）:
echo   - nofx-linux (Linux 后端可执行文件)
echo   - web\dist\ (前端静态文件)
echo.
echo 📦 部署说明:
echo   1. 将 nofx-linux 上传到 Ubuntu 服务器
echo   2. 在 Ubuntu 上执行: chmod +x nofx-linux
echo   3. 将 web\dist 目录上传到 Ubuntu 服务器
echo   4. 确保 config.json 配置文件已配置
echo   5. 运行: ./nofx-linux
echo.
pause

