#!/bin/bash
# ============================================================================
# LTPP 一键部署脚本
#
# 综合自 eastspire/Install 项目的 ltpp.sh / ltpp-code-run.sh / ltpp-ssh.sh，
# 在全新 Linux 主机上从零拉取主程序二进制 + Docker 镜像 + 启动 LTPP 容器栈。
#
# 用法:
#   # 1. 交互式菜单（默认）
#   sudo bash install.sh
#
#   # 2. 非交互：只装主服务 LTPP
#   sudo bash install.sh --component main --yes
#
#   # 3. 非交互：装主服务 + 判题机 + SSH 内网穿透
#   sudo bash install.sh --component all --yes
#
#   # 4. 自定义主程序下载源（默认走 GitHub Release）
#   sudo bash install.sh --binary-url https://ltpp.vip/downloads/LTPP.tar.gz
#
# 支持系统: CentOS (yum) / Debian / Ubuntu (apt)
# 需要权限: root (脚本会自检)
# ----------------------------------------------------------------------------
# 原脚本版权: eastspire
# 重构版本: 2026-08-16
# ============================================================================

set -u  # 故意不开 -e: 任何一步失败我们都希望继续后续清理

# -------- 常量 --------
readonly SCRIPT_VERSION="1.0.0"
readonly LTPP_HOME="/home/LTPP"
readonly LTPP_NETWORK="LTPP"
readonly DOCKER_IMAGE="ccr.ccs.tencentyun.com/linux_environment/debian:1.0.0"
readonly SANDBOX_PATH="/home/LTPPSANDBOX"
readonly RUNTIME_PATH="/home/LTPP/LTPPRUNTIME"
readonly JUDGE_SRC="/home/LTPP/InstallMust/JudgeServer/judge"
readonly JUDGE_DST="/JudgeServer"
readonly PUBLIC_PATH="/home/LTPP/public"

# 默认下载源（可被 --binary-url 覆盖）
readonly DEFAULT_BINARY_URL="https://github.com/eastspire/LTPP/releases/latest/download/LTPP.tar.gz"

# -------- 颜色 --------
if [ -t 1 ]; then
    C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[1;33m'
    C_BLU=$'\033[0;34m'; C_RST=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_RST=""
fi

log_info()  { echo -e "${C_BLU}[INFO]${C_RST}  $*"; }
log_ok()    { echo -e "${C_GRN}[ OK ]${C_RST}  $*"; }
log_warn()  { echo -e "${C_YEL}[WARN]${C_RST}  $*"; }
log_err()   { echo -e "${C_RED}[FAIL]${C_RST} $*" >&2; }

# -------- 工具函数 --------
die() { log_err "$*"; exit 1; }

detect_pkg_mgr() {
    if command -v yum >/dev/null 2>&1; then echo "yum"; return; fi
    if command -v apt >/dev/null 2>&1; then echo "apt"; return; fi
    die "未检测到 yum 或 apt，仅支持 CentOS / Debian / Ubuntu"
}

require_root() {
    [ "$(id -u)" -eq 0 ] || die "请用 root 运行: sudo bash $0"
}

require_docker() {
    command -v docker >/dev/null 2>&1 || die "未安装 docker，请先安装: https://docs.docker.com/engine/install/"
    docker info >/dev/null 2>&1 || die "docker daemon 未运行，请执行: systemctl start docker"
}

calc_cpu_limit() {
    local cores memory
    cores=$(nproc)
    # 公式来自原 ltpp.sh: cpu_source = cores/5, limit = cpu_source*2
    local cpu_source
    cpu_source=$(awk "BEGIN {printf \"%.1f\", $cores/5}")
    awk "BEGIN {printf \"%.2f\", $cpu_source*2}"
}

# -------- 步骤函数 --------
install_base_deps() {
    local mgr="$1"
    log_info "安装基础依赖 (gawk / coreutils / bc / curl) ..."
    case "$mgr" in
        yum)
            yum update -y >/dev/null
            yum install -y gawk coreutils bc curl ca-certificates
            ;;
        apt)
            apt update -y >/dev/null
            apt upgrade -y >/dev/null
            apt --fix-broken install -y >/dev/null
            apt install -y gawk coreutils bc curl ca-certificates
            ;;
    esac
    log_ok "基础依赖安装完成"
}

ensure_linux_env_image() {
    if ! docker image inspect "$DOCKER_IMAGE" >/dev/null 2>&1; then
        log_info "拉取 Docker 镜像: $DOCKER_IMAGE"
        docker pull "$DOCKER_IMAGE" || die "镜像拉取失败，请检查网络或镜像源"
    else
        log_ok "Docker 镜像已存在: $DOCKER_IMAGE"
    fi
}

download_main_binary() {
    local url="$1"
    log_info "下载主程序: $url"
    mkdir -p "$LTPP_HOME"
    # 用 curl 写到临时位置，下载完成再解压 / 复制
    local tmp_tar="/tmp/ltpp_main_$$.tar.gz"
    if ! curl -fL --retry 3 --connect-timeout 15 -o "$tmp_tar" "$url"; then
        rm -f "$tmp_tar"
        die "主程序下载失败: $url"
    fi
    # 假设归档是 tar.gz，直接展开到 $LTPP_HOME
    tar -xzf "$tmp_tar" -C "$LTPP_HOME" \
        || die "主程序解压失败，请确认归档格式"
    rm -f "$tmp_tar"
    log_ok "主程序已就位: $LTPP_HOME"
}

ensure_ltppsandbox() {
    # 重建沙箱目录并挂载 proc（与原 ltpp.sh 一致）
    mkdir -p "$SANDBOX_PATH/proc"
    mount -t proc none "$SANDBOX_PATH/proc" 2>/dev/null || \
        log_warn "挂载 proc 失败（容器内正常，宿主机可忽略）"
}

start_main() {
    local cpu_limit="$1"
    log_info "启动主容器 LTPP（端口 47272 / 48787）..."
    docker network create "$LTPP_NETWORK" >/dev/null 2>&1 || true
    docker rm -f LTPP >/dev/null 2>&1 || true
    chmod -R 555 "$LTPP_HOME" 2>/dev/null
    chmod -R 777 "$LTPP_HOME/DockerData" 2>/dev/null

    docker run -itd \
        --name="LTPP" \
        --network "$LTPP_NETWORK" \
        -p 47272:47272 \
        -p 48787:48787 \
        --init \
        --cpus="$cpu_limit" \
        --restart=always \
        --privileged=true \
        --memory=8g \
        -v "$LTPP_HOME:$LTPP_HOME" \
        "$DOCKER_IMAGE" \
        /bin/bash -c "cd /tmp >/dev/null 2>&1; \
            rm -rf $RUNTIME_PATH >/dev/null 2>&1; \
            nohup $LTPP_HOME/LTPP start -d >/dev/null 2>&1; \
            tail -f /dev/null"
    log_ok "主容器 LTPP 已启动"
}

start_code_run() {
    local cpu_limit="$1"
    log_info "启动判题容器 LTPP-CODE-RUN（端口 8787）..."
    docker rm -f LTPP-CODE-RUN >/dev/null 2>&1 || true

    docker run -itd \
        --name="LTPP-CODE-RUN" \
        --init \
        --cpus="$cpu_limit" \
        --restart=always \
        --privileged=true \
        --memory=2g \
        -p 8787:8787 \
        -v "$LTPP_HOME/LTPP-CODE-RUN:$LTPP_HOME/LTPP-CODE-RUN" \
        -v "$JUDGE_SRC:$JUDGE_SRC" \
        "$DOCKER_IMAGE" \
        /bin/bash -c "cd /tmp >/dev/null 2>&1; \
            nohup $LTPP_HOME/LTPP-CODE-RUN start -d >/dev/null 2>&1; \
            tail -f /dev/null"
    log_ok "判题容器 LTPP-CODE-RUN 已启动"
}

start_ssh() {
    log_info "启动 SSH 内网穿透 LTPP-SSH..."
    if [ ! -x "$LTPP_HOME/LTPP-SSH" ]; then
        log_warn "未找到 $LTPP_HOME/LTPP-SSH，跳过 SSH 组件"
        return 0
    fi
    chmod 555 "$LTPP_HOME/LTPP-SSH"
    nohup "$LTPP_HOME/LTPP-SSH" start -d >/dev/null 2>&1 &
    log_ok "SSH 组件已后台启动"
}

# -------- 交互菜单 --------
interactive_menu() {
    echo
    echo "================================================="
    echo "  LTPP 一键部署 v${SCRIPT_VERSION}"
    echo "================================================="
    echo "  1) 仅主服务 LTPP (端口 47272 / 48787)"
    echo "  2) 主服务 + 判题机 (含 LTPP-CODE-RUN 8787)"
    echo "  3) 全部组件 (主 + 判题 + SSH 穿透)"
    echo "  4) 仅下载主程序 (不启动容器)"
    echo "  q) 退出"
    echo "================================================="
    local choice
    read -rp "请选择 [1-4 / q]: " choice
    case "$choice" in
        1) echo "main" ;;
        2) echo "main+coderun" ;;
        3) echo "all" ;;
        4) echo "download" ;;
        q|Q) exit 0 ;;
        *) die "无效选项: $choice" ;;
    esac
}

# -------- 参数解析 --------
COMPONENT=""
ASSUME_YES=0
BINARY_URL="$DEFAULT_BINARY_URL"

while [ $# -gt 0 ]; do
    case "$1" in
        --component)
            COMPONENT="$2"; shift 2 ;;
        --component=*)
            COMPONENT="${1#*=}"; shift ;;
        --binary-url)
            BINARY_URL="$2"; shift 2 ;;
        --binary-url=*)
            BINARY_URL="${1#*=}"; shift ;;
        -y|--yes)
            ASSUME_YES=1; shift ;;
        -h|--help)
            sed -n '2,25p' "$0"; exit 0 ;;
        *)
            die "未知参数: $1（用 --help 查看用法）" ;;
    esac
done

# -------- 主流程 --------
main() {
    log_info "LTPP 一键部署 v${SCRIPT_VERSION} 启动"
    require_root
    local pkg_mgr
    pkg_mgr=$(detect_pkg_mgr)
    require_docker
    install_base_deps "$pkg_mgr"
    ensure_linux_env_image

    # 决定要装哪些组件
    if [ -z "$COMPONENT" ]; then
        COMPONENT=$(interactive_menu)
    fi

    # 总是先拉主程序（除非用户明确说"仅启动"——目前 UI 没暴露，留扩展位）
    download_main_binary "$BINARY_URL"
    ensure_ltppsandbox

    local cpu_limit
    cpu_limit=$(calc_cpu_limit)
    log_info "检测到 $(nproc) 核，分配 CPU 上限: $cpu_limit"

    case "$COMPONENT" in
        main)
            start_main "$cpu_limit"
            ;;
        main+coderun|all|coderun)
            start_main "$cpu_limit"
            if [ "$COMPONENT" = "main+coderun" ] || [ "$COMPONENT" = "all" ]; then
                start_code_run "$cpu_limit"
            fi
            if [ "$COMPONENT" = "all" ]; then
                start_ssh
            fi
            ;;
        download)
            log_ok "仅下载模式，跳过容器启动"
            ;;
        *)
            die "未知组件: $COMPONENT"
            ;;
    esac

    echo
    log_ok "部署完成！"
    echo "  - 访问主服务: http://<host>:47272"
    echo "  - 访问判题机: http://<host>:8787 (如已启用)"
    echo "  - 查看容器:   docker ps"
    echo "  - 查看日志:   docker logs -f LTPP"
}

main "$@"
