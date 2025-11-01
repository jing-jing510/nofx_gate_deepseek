#!/bin/bash

# ═══════════════════════════════════════════════════════════════
# NOFX AI Trading System - Ubuntu/Linux 编译脚本
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
echo "   NOFX AI Trading System - Ubuntu/Linux 编译脚本"
echo "═══════════════════════════════════════════════════════════════"
echo

# 设置Go代理
export GOPROXY="https://goproxy.cn,direct"
export GO111MODULE="on"

print_info "[1/3] 检查环境..."

# 检查Go
if ! command -v go &> /dev/null; then
    print_error "未找到 Go，请先安装 Go 1.25.0 或更高版本"
    echo "安装方法: https://golang.org/doc/install"
    exit 1
fi

# 检查Node.js
if ! command -v node &> /dev/null; then
    print_error "未找到 Node.js，请先安装 Node.js"
    echo "安装方法: curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - && sudo apt-get install -y nodejs"
    exit 1
fi

# 检查npm
if ! command -v npm &> /dev/null; then
    print_error "未找到 npm，请先安装 npm"
    exit 1
fi

go version
node --version
npm --version
echo

print_info "[2/3] 编译后端..."

go mod tidy
if [ $? -ne 0 ]; then
    print_error "Go依赖整理失败"
    exit 1
fi

go build -o nofx .
if [ $? -ne 0 ]; then
    print_error "后端编译失败"
    exit 1
fi

if [ -f "nofx" ]; then
    print_success "后端编译成功: nofx"
    chmod +x nofx
else
    print_error "后端编译失败: 未找到 nofx"
    exit 1
fi
echo

print_info "[3/3] 编译前端..."

cd web

print_info "配置 npm 使用国内镜像..."
npm config set registry https://registry.npmmirror.com

print_info "安装前端依赖..."
npm install
if [ $? -ne 0 ]; then
    print_error "前端依赖安装失败"
    cd ..
    exit 1
fi

print_info "编译前端..."
npm run build
if [ $? -ne 0 ]; then
    print_error "前端编译失败"
    cd ..
    exit 1
fi

cd ..

if [ -d "web/dist" ]; then
    print_success "前端编译成功: web/dist"
else
    print_error "前端编译失败: 未找到 web/dist"
    exit 1
fi
echo

echo "═══════════════════════════════════════════════════════════════"
print_success "编译完成！"
echo "═══════════════════════════════════════════════════════════════"
echo
echo "生成的文件:"
echo "  - nofx (后端可执行文件)"
echo "  - web/dist/ (前端静态文件)"
echo

