#!/bin/bash

# ═══════════════════════════════════════════════════════════════
# NOFX AI Trading System - Ubuntu/Linux 启动脚本
# ═══════════════════════════════════════════════════════════════

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

echo "═══════════════════════════════════════════════════════════════"
echo "   NOFX AI Trading System - Ubuntu/Linux 启动脚本"
echo "═══════════════════════════════════════════════════════════════"
echo

# 检查后端可执行文件（支持 nofx-linux 和 nofx）
BINARY_NAME=""
if [ -f "nofx-linux" ]; then
    BINARY_NAME="nofx-linux"
    # 如果存在 nofx-linux，确保它有执行权限
    chmod +x nofx-linux
    print_info "检测到 nofx-linux（Windows 交叉编译版本）"
elif [ -f "nofx" ]; then
    BINARY_NAME="nofx"
    chmod +x nofx
else
    print_error "未找到 nofx 或 nofx-linux"
    echo "请先运行 ./build.sh 编译项目，或上传编译好的 nofx-linux 文件"
    exit 1
fi

# 检查前端目录
if [ ! -d "web" ]; then
    print_error "未找到 web 目录"
    exit 1
fi

# 检查前端依赖是否已安装
if [ ! -d "web/node_modules" ]; then
    print_warning "前端依赖未安装，正在安装..."
    cd web
    npm install
    if [ $? -ne 0 ]; then
        print_error "前端依赖安装失败"
        cd ..
        exit 1
    fi
    cd ..
fi

# 检查配置文件
if [ ! -f "config.json" ]; then
    print_error "未找到 config.json"
    echo "请先复制 config.json.example 并配置"
    exit 1
fi

# 设置端口（从配置文件读取，默认8080）
API_PORT=8080
FRONTEND_PORT=3000

print_info "启动参数:"
echo "  - 后端API端口: $API_PORT"
echo "  - 前端端口: $FRONTEND_PORT"
echo "  - 配置文件: config.json"
echo

# 函数：清理并退出
cleanup() {
    echo
    print_info "正在停止服务..."
    kill $BACKEND_PID 2>/dev/null || true
    kill $FRONTEND_PID 2>/dev/null || true
    print_success "服务已停止"
    exit 0
}

# 捕获退出信号
trap cleanup SIGINT SIGTERM

# 启动后端
print_info "[1/2] 启动后端服务..."
./$BINARY_NAME config.json > backend.log 2>&1 &
BACKEND_PID=$!

# 等待后端启动
sleep 3

# 检查后端是否启动成功
if curl -s http://localhost:$API_PORT/health > /dev/null 2>&1; then
    print_success "后端已启动: http://localhost:$API_PORT (PID: $BACKEND_PID)"
else
    print_warning "后端可能未成功启动，请检查 backend.log"
fi

echo

# 启动前端（使用Vite开发服务器，支持API代理）
print_info "[2/2] 启动前端服务..."

# 检查是否有npm
if ! command -v npm &> /dev/null; then
    print_error "未找到 npm"
    echo "请先安装 Node.js: https://nodejs.org/"
    kill $BACKEND_PID 2>/dev/null || true
    exit 1
fi

print_info "使用 Vite 开发服务器（支持API代理）..."
cd web
npm run dev > ../frontend.log 2>&1 &
FRONTEND_PID=$!
cd ..
sleep 2
print_success "前端已启动: http://localhost:$FRONTEND_PORT (PID: $FRONTEND_PID)"
echo
echo "═══════════════════════════════════════════════════════════════"
print_success "服务启动完成！"
echo "═══════════════════════════════════════════════════════════════"
echo
echo "访问地址:"
echo "  - 前端界面: http://localhost:$FRONTEND_PORT"
echo "  - API接口: http://localhost:$API_PORT"
echo
echo "日志文件:"
echo "  - 后端日志: backend.log"
echo "  - 前端日志: frontend.log"
echo
echo "注意: 前端使用 Vite 开发服务器，会自动代理 /api 请求到后端"
echo
print_info "按 Ctrl+C 停止服务"
echo

# 等待用户中断
wait
