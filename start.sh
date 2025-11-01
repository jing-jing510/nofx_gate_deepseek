#!/bin/bash

# ═══════════════════════════════════════════════════════════════
# NOFX AI Trading System - Ubuntu/Linux 管理脚本
# ═══════════════════════════════════════════════════════════════

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# PID 文件路径
PID_DIR="./.pids"
BACKEND_PID_FILE="$PID_DIR/backend.pid"
FRONTEND_PID_FILE="$PID_DIR/frontend.pid"

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

# 检查后端可执行文件
check_binary() {
    local binary_name=""
    if [ -f "nofx-linux" ]; then
        binary_name="nofx-linux"
        chmod +x nofx-linux
        print_info "检测到 nofx-linux（Windows 交叉编译版本）" >&2
    elif [ -f "nofx" ]; then
        binary_name="nofx"
        chmod +x nofx
    else
        print_error "未找到 nofx 或 nofx-linux" >&2
        echo "请先运行 ./build.sh 编译项目，或上传编译好的 nofx-linux 文件" >&2
        exit 1
    fi
    echo "$binary_name"
}

# 检查服务是否运行
is_running() {
    local pid_file=$1
    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file")
        if ps -p "$pid" > /dev/null 2>&1; then
            return 0
        else
            # PID 文件存在但进程不存在，清理 PID 文件
            rm -f "$pid_file"
            return 1
        fi
    fi
    return 1
}

# 启动服务
start_services() {
    echo "═══════════════════════════════════════════════════════════════"
    echo "   NOFX AI Trading System - 启动服务"
    echo "═══════════════════════════════════════════════════════════════"
    echo

    # 检查是否已运行
    if is_running "$BACKEND_PID_FILE" || is_running "$FRONTEND_PID_FILE"; then
        print_warning "服务已在运行中"
        show_status
        exit 1
    fi

    # 检查配置文件
    if [ ! -f "config.json" ]; then
        print_error "未找到 config.json"
        echo "请先复制 config.json.example 并配置"
        exit 1
    fi

    # 获取二进制文件名
    BINARY_NAME=$(check_binary)

    # 创建 PID 目录
    mkdir -p "$PID_DIR"

    # 设置端口
    API_PORT=8080
    FRONTEND_PORT=3000

    print_info "启动参数:"
    echo "  - 后端API端口: $API_PORT"
    echo "  - 前端端口: $FRONTEND_PORT"
    echo "  - 配置文件: config.json"
    echo

    # 启动后端
    print_info "[1/2] 启动后端服务（后台运行）..."
    print_info "使用二进制文件: $BINARY_NAME"
    
    if [ ! -f "$BINARY_NAME" ]; then
        print_error "二进制文件不存在: $BINARY_NAME"
        exit 1
    fi
    
    ./"$BINARY_NAME" config.json > backend.log 2>&1 &
    BACKEND_PID=$!
    echo $BACKEND_PID > "$BACKEND_PID_FILE"
    
    sleep 3
    
    if is_running "$BACKEND_PID_FILE"; then
        print_success "后端已启动: http://localhost:$API_PORT (PID: $BACKEND_PID)"
    else
        print_error "后端启动失败，请检查 backend.log"
        print_info "最后10行日志:"
        tail -n 10 backend.log 2>/dev/null || echo "日志文件为空或不存在"
        rm -f "$BACKEND_PID_FILE"
        exit 1
    fi

    # 检查前端目录
    if [ ! -d "web" ]; then
        print_warning "未找到 web 目录，跳过前端启动"
        echo
        print_success "后端服务已启动"
        echo "  访问地址: http://localhost:$API_PORT"
        echo "  查看日志: ./start.sh logs"
        exit 0
    fi

    # 检查前端依赖
    if [ ! -d "web/node_modules" ]; then
        print_warning "前端依赖未安装，正在安装..."
        cd web
        npm install > /dev/null 2>&1
        cd ..
    fi

    # 检查 npm
    if ! command -v npm &> /dev/null; then
        print_warning "未找到 npm，跳过前端启动"
        echo
        print_success "后端服务已启动"
        echo "  访问地址: http://localhost:$API_PORT"
        echo "  查看日志: ./start.sh logs"
        exit 0
    fi

    # 启动前端
    print_info "[2/2] 启动前端服务（后台运行）..."
    cd web
    npm run dev > ../frontend.log 2>&1 &
    FRONTEND_PID=$!
    echo $FRONTEND_PID > "../$FRONTEND_PID_FILE"
    cd ..
    
    sleep 2
    
    if is_running "../$FRONTEND_PID_FILE"; then
        print_success "前端已启动: http://localhost:$FRONTEND_PORT (PID: $FRONTEND_PID)"
    else
        print_warning "前端可能启动失败，请检查 frontend.log"
    fi

    echo
    echo "═══════════════════════════════════════════════════════════════"
    print_success "服务启动完成！"
    echo "═══════════════════════════════════════════════════════════════"
    echo
    echo "访问地址:"
    echo "  - 前端界面: http://localhost:$FRONTEND_PORT"
    echo "  - API接口: http://localhost:$API_PORT"
    echo
    echo "管理命令:"
    echo "  ./start.sh status  - 查看服务状态"
    echo "  ./start.sh logs    - 查看所有日志"
    echo "  ./start.sh stop    - 停止服务"
    echo
}

# 停止服务
stop_services() {
    echo "═══════════════════════════════════════════════════════════════"
    echo "   NOFX AI Trading System - 停止服务"
    echo "═══════════════════════════════════════════════════════════════"
    echo

    stopped=0

    # 停止前端
    if is_running "$FRONTEND_PID_FILE"; then
        FRONTEND_PID=$(cat "$FRONTEND_PID_FILE")
        print_info "停止前端服务 (PID: $FRONTEND_PID)..."
        kill "$FRONTEND_PID" 2>/dev/null || true
        sleep 1
        # 强制杀死（如果还在运行）
        kill -9 "$FRONTEND_PID" 2>/dev/null || true
        rm -f "$FRONTEND_PID_FILE"
        print_success "前端服务已停止"
        stopped=1
    fi

    # 停止后端
    if is_running "$BACKEND_PID_FILE"; then
        BACKEND_PID=$(cat "$BACKEND_PID_FILE")
        print_info "停止后端服务 (PID: $BACKEND_PID)..."
        kill "$BACKEND_PID" 2>/dev/null || true
        sleep 1
        # 强制杀死（如果还在运行）
        kill -9 "$BACKEND_PID" 2>/dev/null || true
        rm -f "$BACKEND_PID_FILE"
        print_success "后端服务已停止"
        stopped=1
    fi

    if [ $stopped -eq 0 ]; then
        print_warning "服务未运行"
    fi

    # 清理 PID 目录（如果为空）
    rmdir "$PID_DIR" 2>/dev/null || true
}

# 查看状态
show_status() {
    echo "═══════════════════════════════════════════════════════════════"
    echo "   NOFX AI Trading System - 服务状态"
    echo "═══════════════════════════════════════════════════════════════"
    echo

    backend_running=false
    frontend_running=false

    if is_running "$BACKEND_PID_FILE"; then
        BACKEND_PID=$(cat "$BACKEND_PID_FILE")
        print_success "后端服务: 运行中 (PID: $BACKEND_PID)"
        echo "  访问地址: http://localhost:8080"
        backend_running=true
    else
        print_error "后端服务: 未运行"
    fi

    echo

    if is_running "$FRONTEND_PID_FILE"; then
        FRONTEND_PID=$(cat "$FRONTEND_PID_FILE")
        print_success "前端服务: 运行中 (PID: $FRONTEND_PID)"
        echo "  访问地址: http://localhost:3000"
        frontend_running=true
    else
        print_error "前端服务: 未运行"
    fi

    echo

    if [ "$backend_running" = true ] || [ "$frontend_running" = true ]; then
        echo "日志文件:"
        [ -f "backend.log" ] && echo "  - backend.log ($(du -h backend.log | cut -f1))"
        [ -f "frontend.log" ] && echo "  - frontend.log ($(du -h frontend.log | cut -f1))"
        echo
        echo "查看日志: ./start.sh logs"
    fi
}

# 查看日志
show_logs() {
    local log_type=${1:-all}

    case "$log_type" in
        backend)
            if [ -f "backend.log" ]; then
                print_info "后端日志 (Ctrl+C 退出):"
                echo "═══════════════════════════════════════════════════════════════"
                tail -f backend.log
            else
                print_error "后端日志文件不存在"
            fi
            ;;
        frontend)
            if [ -f "frontend.log" ]; then
                print_info "前端日志 (Ctrl+C 退出):"
                echo "═══════════════════════════════════════════════════════════════"
                tail -f frontend.log
            else
                print_error "前端日志文件不存在"
            fi
            ;;
        all|*)
            print_info "所有日志 (Ctrl+C 退出):"
            echo "═══════════════════════════════════════════════════════════════"
            
            if [ -f "backend.log" ] && [ -f "frontend.log" ]; then
                # 同时显示两个日志文件
                tail -f backend.log frontend.log 2>/dev/null || {
                    # 如果 tail 不支持多个文件，使用多进程
                    (tail -f backend.log 2>/dev/null &) && tail -f frontend.log
                }
            elif [ -f "backend.log" ]; then
                tail -f backend.log
            elif [ -f "frontend.log" ]; then
                tail -f frontend.log
            else
                print_error "日志文件不存在"
            fi
            ;;
    esac
}

# 重启服务
restart_services() {
    echo "═══════════════════════════════════════════════════════════════"
    echo "   NOFX AI Trading System - 重启服务"
    echo "═══════════════════════════════════════════════════════════════"
    echo
    
    stop_services
    sleep 2
    start_services
}

# 显示帮助
show_help() {
    echo "═══════════════════════════════════════════════════════════════"
    echo "   NOFX AI Trading System - 使用帮助"
    echo "═══════════════════════════════════════════════════════════════"
    echo
    echo "使用方法: ./start.sh [command]"
    echo
    echo "可用命令:"
    echo "  start          - 后台启动服务"
    echo "  stop           - 停止所有服务"
    echo "  restart        - 重启所有服务"
    echo "  status         - 查看服务状态"
    echo "  logs           - 查看所有日志（实时，Ctrl+C 退出）"
    echo "  logs backend   - 查看后端日志"
    echo "  logs frontend  - 查看前端日志"
    echo "  help           - 显示此帮助信息"
    echo
    echo "示例:"
    echo "  ./start.sh start           # 启动服务"
    echo "  ./start.sh logs            # 查看所有日志"
    echo "  ./start.sh logs backend    # 只查看后端日志"
    echo "  ./start.sh status          # 查看状态"
    echo
}

# 主逻辑
case "${1:-start}" in
    start)
        start_services
        ;;
    stop)
        stop_services
        ;;
    restart)
        restart_services
        ;;
    status)
        show_status
        ;;
    logs)
        show_logs "$2"
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        print_error "未知命令: $1"
        echo
        show_help
        exit 1
        ;;
esac
