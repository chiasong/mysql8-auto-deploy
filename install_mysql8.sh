#!/bin/bash
# ==============================================================================
# MySQL 8.0.46 生产级自动化部署脚本 (解决 Row size too large 8126 终极配置加固版)
# 1. 【Row Size 太大问题修复】配置 innodb_strict_mode = 0 与 innodb_default_row_format = DYNAMIC，
#    彻底解决应用系统报错 Row size too large (> 8126) 的问题
# 2. 【密码修改安全隔离】Step 9 使用 set +e 包裹 mysql 执行块，防止非零退出码触发 set -e 导致脚本提前中断
# 3. 【错误捕获强化】密码更新失败时全自动打印详细 SQL 报错
# 4. 【软链接防死循环】设计安全建链函数 safe_symlink，彻底根治 libaio.so.1 -> libaio.so.1 循环指向 Bug
# 5. 【实体文件过滤】find 命令强制使用 -type f -name "libaio.so*" ! -name "libaio.so.1" 仅匹配真实文件
# 6. 【初始化探针】增加 --console 参数，强制 mysqld --initialize 将临时密码与报错推送到 stderr
# 7. 【双重日志扫描】同时扫描初始化日志与 ${LOG_DIR}/mysql.log，彻底解决日志空输出问题
# 8. 【RedHat/CentOS】完美融入 yum -y install libaio perl perl-devel
# 9. 【Debian/Ubuntu 常规版】完美融入 apt-get install -y libaio1
# 10.【Ubuntu 24LTS/22LTS 专治版】融入 apt install numactl libaio1t64 -y 并自动建立相关软链接
# 11.【信号捕获与垃圾清理】捕获 INT/TERM/EXIT 信号，退出或中断全自动清理临时分块与后台下载子进程
# 12.【Socket 就绪轮询】动态 Socket/Ping 探测轮询循环，彻底解决密码修改时 Socket 未就绪问题
# 13.【防火墙与 SELinux】自动识别 firewalld / ufw 状态，全自动放行配置端口
# 14.【高可靠原生分片下载】8 线程 HTTP 206 校验 + 单分片独立重试 + 边拼边删流式释放空间 + 孤儿进程治理
# 15.【全链路安全加固】数据目录非空覆盖交互确认 + 密码日志权限收紧 (chmod 600) + 部署完成清理暂存包
# ==============================================================================

set -eo pipefail

# ------------------------------------------------------------------------------
# 1. 全局变量定义与 Trap 信号捕获清理
# ------------------------------------------------------------------------------
MYSQL_VERSION="8.0.46"
MYSQL_USER="mysql"
MYSQL_GROUP="mysql"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PARALLEL_PIDS=()
DOWNLOAD_CHUNK_DIR=""
TMP_DOWNLOAD_DIR=""
INIT_LOG=""
PASS_UPDATE_LOG=""

log_info() { echo -e "${GREEN}[INFO] $1${NC}"; }
log_warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }
log_err()  { echo -e "${RED}[ERROR] $1${NC}"; }
log_step() { echo -e "\n${BLUE}========== $1 ==========${NC}"; }

# 捕获脚本中断与退出信号，全自动清理临时垃圾与后台孤儿进程
cleanup_on_exit() {
    local exit_code=$?

    # 1. 终止可能仍在后台运行的并发下载子进程，防止孤儿进程持续占用网络带宽
    if [ ${#PARALLEL_PIDS[@]} -gt 0 ]; then
        for pid in "${PARALLEL_PIDS[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                kill -TERM "$pid" 2>/dev/null || true
            fi
        done
        wait 2>/dev/null || true
    fi

    # 2. 清理分块临时目录
    if [ -n "${DOWNLOAD_CHUNK_DIR}" ] && [ -d "${DOWNLOAD_CHUNK_DIR}" ]; then
        rm -rf "${DOWNLOAD_CHUNK_DIR}" 2>/dev/null || true
    fi
    if [ -d "/tmp/mysql_chunks_$$" ]; then
        rm -rf "/tmp/mysql_chunks_$$" 2>/dev/null || true
    fi

    # 3. 清理包含敏感密码的临时日志
    if [ -n "${INIT_LOG}" ] && [ -f "${INIT_LOG}" ]; then
        rm -f "${INIT_LOG}" 2>/dev/null || true
    fi
    if [ -n "${PASS_UPDATE_LOG}" ] && [ -f "${PASS_UPDATE_LOG}" ]; then
        rm -f "${PASS_UPDATE_LOG}" 2>/dev/null || true
    fi

    if [ $exit_code -ne 0 ]; then
        log_warn "检测到脚本异常退出 (Code: ${exit_code})，已完成临时垃圾文件与后台进程清理。"
    fi
}
trap cleanup_on_exit EXIT INT TERM

# ------------------------------------------------------------------------------
# 2. 检查 root 权限
# ------------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    log_err "请使用 root 权限或 sudo 运行此脚本！"
    exit 1
fi

# ------------------------------------------------------------------------------
# 3. 交互式选择部署路径与端口
# ------------------------------------------------------------------------------
log_step "Step 1: 交互式配置部署路径与服务端口"

# 输入部署主路径
read -p "请输入 MySQL 部署主路径 [默认 /data/mysql8]: " INPUT_BASE_DIR
BASE_DIR="${INPUT_BASE_DIR:-/data/mysql8}"

INSTALL_DIR="${BASE_DIR}"
DATA_DIR="${BASE_DIR}/datas"
LOG_DIR="${BASE_DIR}/logs"

log_info "部署主路径: ${BASE_DIR}"
log_info "数据存储目录: ${DATA_DIR}"
log_info "日志存储目录: ${LOG_DIR}"

# 选择部署环境模式
echo ""
log_info "请选择 MySQL 部署运行模式:"
echo "  1) 生产高性能模式 [默认] (按内存 50%~60% 动态分配 Buffer Pool，开启 Performance Schema，大并发连接池)"
echo "  2) 测试/轻量节能模式 (低常驻内存 ~200MB，关闭 Performance Schema，精简 Session 缓存，适合开发/测试/低配环境)"
read -p "请输入模式序号 [1-2, 默认 1]: " INPUT_MODE
DEPLOY_MODE="${INPUT_MODE:-1}"
if [ "${DEPLOY_MODE}" != "2" ]; then
    DEPLOY_MODE="1"
    DEPLOY_MODE_NAME="生产高性能模式"
else
    DEPLOY_MODE_NAME="测试/轻量节能模式"
fi
log_info "已选定部署模式: ${DEPLOY_MODE_NAME}"

# 输入端口及检测占用
get_custom_port() {
    while true; do
        read -p "请输入 MySQL 服务端口 [默认 3306]: " INPUT_PORT
        PORT=${INPUT_PORT:-3306}
        
        if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
            log_err "端口号无效！请输入 1-65535 之间的有效数字。"
            continue
        fi

        PORT_OCCUPIED=0
        if command -v ss >/dev/null 2>&1; then
            if ss -tuln | grep -qE ":${PORT}\b"; then PORT_OCCUPIED=1; fi
        elif command -v netstat >/dev/null 2>&1; then
            if netstat -tuln | grep -qE ":${PORT}\b"; then PORT_OCCUPIED=1; fi
        elif command -v lsof >/dev/null 2>&1; then
            if lsof -i:${PORT} >/dev/null 2>&1; then PORT_OCCUPIED=1; fi
        fi

        if [ "$PORT_OCCUPIED" -eq 1 ]; then
            log_err "【警告】端口 ${PORT} 当前已被系统其他进程占用！请重新输入未占用的端口。"
        else
            log_info "端口 ${PORT} 检查通过，未被占用。"
            break
        fi
    done
}

get_custom_port

# ------------------------------------------------------------------------------
# 4. 识别系统的 glibc 版本、CPU 架构与物理内存
# ------------------------------------------------------------------------------
log_step "Step 2: 识别系统环境与硬件资源"

get_glibc_version() {
    local ver=""
    if command -v getconf >/dev/null 2>&1; then
        ver=$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}')
    fi
    if [ -z "$ver" ]; then
        ver=$(ldd --version 2>/dev/null | head -n 1 | grep -oE '[0-9]+\.[0-9]+' | head -n 1)
    fi
    echo "$ver"
}

version_ge() {
    awk -v v1="$1" -v v2="$2" 'BEGIN {
        split(v1, a, "."); split(v2, b, ".");
        n1 = a[1]*10000 + a[2]*100 + (a[3]?a[3]:0);
        n2 = b[1]*10000 + b[2]*100 + (b[3]?b[3]:0);
        if (n1 >= n2) exit 0; else exit 1;
    }'
}

GLIBC_VER=$(get_glibc_version)
ARCH=$(uname -m)

if [ -z "$GLIBC_VER" ]; then
    log_err "无法检测到系统的 glibc 版本，请检查系统环境。"
    exit 1
fi

log_info "系统 CPU 架构: ${ARCH}"
log_info "系统 glibc 版本: ${GLIBC_VER}"

GLIBC_TAG=""
if version_ge "$GLIBC_VER" "2.28"; then
    GLIBC_TAG="glibc2.28"
elif version_ge "$GLIBC_VER" "2.17"; then
    GLIBC_TAG="glibc2.17"
else
    log_err "系统 glibc 版本 (${GLIBC_VER}) 低于 2.17，MySQL 8.0.46 官方二进制包不支持该系统！"
    exit 1
fi

ARCH_TAG=""
case "$ARCH" in
    x86_64|amd64) ARCH_TAG="x86_64" ;;
    aarch64|arm64) ARCH_TAG="aarch64" ;;
    *) log_err "暂不支持的 CPU 架构: ${ARCH}"; exit 1 ;;
esac

TAR_FILE="mysql-${MYSQL_VERSION}-linux-${GLIBC_TAG}-${ARCH_TAG}.tar.xz"

# 智能识别内存并按部署模式分配内存与缓存参数
TOTAL_MEM_MB=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}' || echo 4096)
if [ -z "$TOTAL_MEM_MB" ] || [ "$TOTAL_MEM_MB" -le 0 ]; then
    TOTAL_MEM_MB=4096
fi
log_info "系统总物理内存: ${TOTAL_MEM_MB} MB"

if [ "${DEPLOY_MODE}" = "2" ]; then
    # 测试/轻量节能模式（大幅降低常驻内存至 ~200MB，防止小内存机 OOM）
    if [ "$TOTAL_MEM_MB" -ge 4096 ]; then
        BUFFER_POOL_MB=512
    else
        BUFFER_POOL_MB=256
    fi
    BUFFER_POOL_SIZE="${BUFFER_POOL_MB}M"
    BUFFER_POOL_INSTANCES=1
    PERFORMANCE_SCHEMA="OFF"
    MAX_CONNECTIONS=150
    BINLOG_CACHE_SIZE="1M"
    INNODB_LOG_BUFFER_SIZE="16M"
    INNODB_SORT_BUFFER_SIZE="16M"
    TMP_TABLE_SIZE="32M"
    MAX_HEAP_TABLE_SIZE="32M"
    SORT_BUFFER_SIZE="512K"
    JOIN_BUFFER_SIZE="512K"
    READ_BUFFER_SIZE="256K"
    READ_RND_BUFFER_SIZE="512K"
    BULK_INSERT_BUFFER_SIZE="8M"
    TABLE_OPEN_CACHE=500
    TABLE_DEFINITION_CACHE=400
else
    # 生产高性能模式（充分利用硬件内存与高并发连接池）
    if [ "$TOTAL_MEM_MB" -ge 16384 ]; then
        BUFFER_POOL_MB=$(( TOTAL_MEM_MB * 60 / 100 ))
        BUFFER_POOL_INSTANCES=8
    elif [ "$TOTAL_MEM_MB" -ge 4096 ]; then
        BUFFER_POOL_MB=$(( TOTAL_MEM_MB * 50 / 100 ))
        BUFFER_POOL_INSTANCES=4
    else
        BUFFER_POOL_MB=1024
        BUFFER_POOL_INSTANCES=1
    fi
    BUFFER_POOL_SIZE="${BUFFER_POOL_MB}M"
    PERFORMANCE_SCHEMA="ON"
    MAX_CONNECTIONS=2000
    BINLOG_CACHE_SIZE="32M"
    INNODB_LOG_BUFFER_SIZE="64M"
    INNODB_SORT_BUFFER_SIZE="64M"
    TMP_TABLE_SIZE="256M"
    MAX_HEAP_TABLE_SIZE="256M"
    SORT_BUFFER_SIZE="2M"
    JOIN_BUFFER_SIZE="2M"
    READ_BUFFER_SIZE="2M"
    READ_RND_BUFFER_SIZE="2M"
    BULK_INSERT_BUFFER_SIZE="32M"
    TABLE_OPEN_CACHE=2000
    TABLE_DEFINITION_CACHE=1400
fi

log_info "运行模式: ${DEPLOY_MODE_NAME}"
log_info "自动匹配 InnoDB Buffer Pool: ${BUFFER_POOL_SIZE} (Instances: ${BUFFER_POOL_INSTANCES})"
log_info "Performance Schema 状态: ${PERFORMANCE_SCHEMA}"
log_info "最大连接数 (max_connections): ${MAX_CONNECTIONS}"

# ------------------------------------------------------------------------------
# 5. 安全创建软链接函数 (防止指向自身导致死循环)
# ------------------------------------------------------------------------------
safe_symlink() {
    local src_file="$1"
    local dest_link="$2"

    if [ -z "${src_file}" ] || [ -z "${dest_link}" ]; then
        return 0
    fi

    if [ ! -f "${src_file}" ] && [ ! -L "${src_file}" ]; then
        return 0
    fi

    local real_src=$(readlink -f "${src_file}" 2>/dev/null || echo "${src_file}")
    local real_dest_dir=$(dirname "${dest_link}")

    if [ "${src_file}" = "${dest_link}" ] || [ "${real_src}" = "${dest_link}" ]; then
        return 0
    fi

    mkdir -p "${real_dest_dir}" 2>/dev/null || true
    rm -f "${dest_link}" 2>/dev/null || true
    ln -sf "${real_src}" "${dest_link}" 2>/dev/null || true
    log_info "建立安全软链接: ${dest_link} -> ${real_src}"
}

# ------------------------------------------------------------------------------
# 6. 安装基础依赖（融入 RedHat/Debian/Ubuntu24 特殊解法）
# ------------------------------------------------------------------------------
log_step "Step 3: 安装基础依赖与全平台 libaio 库支持"

install_dependencies() {
    # 清理死循环自引用软链接
    for bad_link in /usr/lib64/libaio.so.1 /lib64/libaio.so.1 /usr/lib/libaio.so.1 /lib/libaio.so.1 /usr/lib/x86_64-linux-gnu/libaio.so.1 /usr/lib/aarch64-linux-gnu/libaio.so.1; do
        if [ -L "${bad_link}" ]; then
            local target=$(readlink "${bad_link}" 2>/dev/null || true)
            if [ "${target}" = "${bad_link}" ] || [ "${target}" = "libaio.so.1" ]; then
                rm -f "${bad_link}" 2>/dev/null || true
            fi
        fi
    done

    # 调整系统 limits.conf
    if [ -f /etc/security/limits.conf ]; then
        if ! grep -q "mysql soft nofile" /etc/security/limits.conf; then
            cat >> /etc/security/limits.conf <<EOF
* soft nofile 65535
* hard nofile 65535
mysql soft nofile 65535
mysql hard nofile 65535
EOF
        fi
    fi

    if command -v yum >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1; then
        local pkg_mgr=$(command -v dnf || command -v yum)
        log_info "检测到 RedHat/CentOS/Rocky 系统，执行 libaio, perl, perl-devel 与 EPEL 安装..."
        
        $pkg_mgr -y install libaio perl perl-devel || true
        
        $pkg_mgr install -y wget || true
        $pkg_mgr install -y tar || true
        $pkg_mgr install -y xz || true
        $pkg_mgr install -y libaio-devel || true
        $pkg_mgr install -y numactl || true
        $pkg_mgr install -y numactl-libs || true
        $pkg_mgr install -y epel-release || true
        $pkg_mgr install -y openssl11-libs || true
        $pkg_mgr install -y openssl11 || true
        $pkg_mgr install -y ncurses-compat-libs || true
        $pkg_mgr install -y ncurses-libs || true

    elif command -v apt-get >/dev/null 2>&1 || command -v apt >/dev/null 2>&1; then
        log_info "检测到 Debian/Ubuntu 系统，执行常规版 libaio1 与 Ubuntu24 特殊包安装..."
        apt-get update -y || true

        apt-get install -y libaio1 || true
        apt-get install -y libaio-dev || true

        apt install -y numactl libaio1t64 || true

        apt-get install -y wget || true
        apt-get install -y tar || true
        apt-get install -y xz-utils || true
        apt-get install -y libnuma1 || true
        apt-get install -y libssl-dev || true
        apt-get install -y openssl || true
        apt-get install -y libncurses5 || true
        apt-get install -y libncurses6 || true
        apt-get install -y libncursesw5 || true
    fi

    log_info "安全校验并构建针对 Ubuntu 24 及通用系统的 libaio.so.1 & libncurses.so.6 软链接..."

    local target_arch_dir=""
    case "${ARCH}" in
        x86_64|amd64) target_arch_dir="/usr/lib/x86_64-linux-gnu" ;;
        aarch64|arm64) target_arch_dir="/usr/lib/aarch64-linux-gnu" ;;
    esac

    if [ -n "${target_arch_dir}" ] && [ -d "${target_arch_dir}" ]; then
        local t64_lib=$(find "${target_arch_dir}" -type f -name "libaio.so.1t64*" 2>/dev/null | head -n 1 || true)
        if [ -n "${t64_lib}" ]; then
            safe_symlink "${t64_lib}" "${target_arch_dir}/libaio.so.1"
        fi

        local nc6_lib=$(find "${target_arch_dir}" -type f -name "libncurses.so.6*" 2>/dev/null | head -n 1 || true)
        if [ -n "${nc6_lib}" ]; then
            safe_symlink "${nc6_lib}" "${target_arch_dir}/libncurses.so.6"
            safe_symlink "${nc6_lib}" "${target_arch_dir}/libncurses.so.5"
        fi
    fi

    local real_aio_file=""
    real_aio_file=$(find /lib64 /usr/lib64 /lib /usr/lib /lib/x86_64-linux-gnu /usr/lib/x86_64-linux-gnu /lib/aarch64-linux-gnu /usr/lib/aarch64-linux-gnu -type f -name "libaio.so*" ! -name "libaio.so.1" 2>/dev/null | head -n 1 || true)

    if [ -n "${real_aio_file}" ]; then
        safe_symlink "${real_aio_file}" /usr/lib64/libaio.so.1
        safe_symlink "${real_aio_file}" /lib64/libaio.so.1
        safe_symlink "${real_aio_file}" /usr/lib/libaio.so.1
        safe_symlink "${real_aio_file}" /lib/libaio.so.1
        if [ -d "/usr/lib/x86_64-linux-gnu" ]; then safe_symlink "${real_aio_file}" /usr/lib/x86_64-linux-gnu/libaio.so.1; fi
        if [ -d "/usr/lib/aarch64-linux-gnu" ]; then safe_symlink "${real_aio_file}" /usr/lib/aarch64-linux-gnu/libaio.so.1; fi
    fi

    local real_ssl_file=""
    real_ssl_file=$(find /lib64 /usr/lib64 /lib /usr/lib /lib/x86_64-linux-gnu /usr/lib/x86_64-linux-gnu /lib/aarch64-linux-gnu /usr/lib/aarch64-linux-gnu -type f -name "libssl.so.1.1*" ! -name "libssl.so.1.1" 2>/dev/null | head -n 1 || true)
    if [ -n "${real_ssl_file}" ]; then
        safe_symlink "${real_ssl_file}" /usr/lib64/libssl.so.1.1
        safe_symlink "${real_ssl_file}" /lib64/libssl.so.1.1
        safe_symlink "${real_ssl_file}" /usr/lib/libssl.so.1.1
        safe_symlink "${real_ssl_file}" /lib/libssl.so.1.1
        if [ -d "/usr/lib/x86_64-linux-gnu" ]; then safe_symlink "${real_ssl_file}" /usr/lib/x86_64-linux-gnu/libssl.so.1.1; fi
    fi

    ldconfig >/dev/null 2>&1 || true
}

install_dependencies

# ------------------------------------------------------------------------------
# 7. 创建 mysql 用户与组
# ------------------------------------------------------------------------------
log_step "Step 4: 创建 mysql 用户与组"

if ! getent group "${MYSQL_GROUP}" >/dev/null 2>&1; then
    groupadd "${MYSQL_GROUP}"
fi

if ! getent passwd "${MYSQL_USER}" >/dev/null 2>&1; then
    useradd -r -g "${MYSQL_GROUP}" -s /bin/false "${MYSQL_USER}"
fi

# ------------------------------------------------------------------------------
# 8. 8 线程黄金并发 Curl Range 分片极速下载 (伪装 User-Agent)
# ------------------------------------------------------------------------------
log_step "Step 5: 8 线程黄金并发分片下载"

TMP_DOWNLOAD_DIR="${BASE_DIR}/tmp_download"
mkdir -p "${TMP_DOWNLOAD_DIR}"
cd "${TMP_DOWNLOAD_DIR}"

UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

# 完整性校验函数：检查文件是否存在、大小是否大于50MB且 xz 校验流是否完整
check_package_integrity() {
    local file="$1"
    if [ ! -f "$file" ]; then
        return 1
    fi
    local file_size
    file_size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo 0)
    if [ "$file_size" -lt 52428800 ]; then
        return 1
    fi
    if command -v xz >/dev/null 2>&1; then
        xz -t "$file" >/dev/null 2>&1 && return 0 || return 1
    elif command -v tar >/dev/null 2>&1; then
        tar -tf "$file" >/dev/null 2>&1 && return 0 || return 1
    fi
    return 0
}

# 单分片下载与独立重试函数
download_single_chunk() {
    local url="$1"
    local chunk_file="$2"
    local start="$3"
    local end="$4"
    local expected_len="$5"
    local max_retries=3
    local retry=0

    # 若已存在且尺寸完全一致，跳过无需重复下载
    if [ -f "${chunk_file}" ]; then
        local cur_sz
        cur_sz=$(stat -c%s "${chunk_file}" 2>/dev/null || stat -f%z "${chunk_file}" 2>/dev/null || echo 0)
        if [ "$cur_sz" -eq "$expected_len" ]; then
            return 0
        fi
    fi

    while [ $retry -lt $max_retries ]; do
        if curl -s -L -A "${UA}" --connect-timeout 15 --retry 3 --retry-delay 2 -r "${start}-${end}" "${url}" -o "${chunk_file}"; then
            local final_sz
            final_sz=$(stat -c%s "${chunk_file}" 2>/dev/null || stat -f%z "${chunk_file}" 2>/dev/null || echo 0)
            if [ "$final_sz" -eq "$expected_len" ]; then
                return 0
            fi
        fi
        retry=$(( retry + 1 ))
        sleep 1
    done
    return 1
}

# 8 并发 Curl 原生 Range 分段下载 + 206 校验 + 边拼边删流式整合函数
parallel_curl_download() {
    local url="$1"
    local output="$2"
    local num_threads=8

    log_info "连接下载节点并探测 HTTP 206 Range 支持: ${url}"

    # 1 字节探针请求，校验服务器是否真正支持 Range 并获取文件总大小
    local probe_headers
    probe_headers=$(curl -s -D - -L -A "${UA}" --connect-timeout 15 -r 0-0 "${url}" -o /dev/null 2>/dev/null || true)

    if ! echo "${probe_headers}" | grep -qE '^HTTP/[0-9.]+ 206'; then
        log_warn "该节点不支持 HTTP 206 Range 分段请求，跳过分片模式并转为断点续传..."
        return 2
    fi

    local content_length=""
    local range_val
    range_val=$(echo "${probe_headers}" | grep -i '^Content-Range:' | tail -n 1 || true)
    if [ -n "${range_val}" ]; then
        content_length=$(echo "${range_val}" | awk -F'/' '{print $2}' | tr -d '\r\n ' | grep -E '^[0-9]+$' || true)
    fi

    if [ -z "$content_length" ] || [ "$content_length" -lt 52428800 ]; then
        content_length=$(echo "${probe_headers}" | grep -i '^Content-Length:' | awk '{print $2}' | tr -d '\r\n ' | grep -E '^[0-9]+$' | tail -n 1 || true)
    fi

    if [ -z "$content_length" ] || [ "$content_length" -lt 52428800 ]; then
        log_warn "获取 Content-Length 异常（未响应或文件小于 50MB），尝试下一节点..."
        return 1
    fi

    local total_mb=$(( content_length / 1048576 ))
    log_info "探测成功！安装包总大小: ${total_mb} MB，已开启 ${num_threads} 线程原生并发分片传输..."

    local chunk_size=$(( content_length / num_threads ))
    DOWNLOAD_CHUNK_DIR="${TMP_DOWNLOAD_DIR}/chunks_$$"
    mkdir -p "${DOWNLOAD_CHUNK_DIR}"

    PARALLEL_PIDS=()
    for ((i=0; i<num_threads; i++)); do
        local start=$(( i * chunk_size ))
        local end=$(( (i + 1) * chunk_size - 1 ))
        if [ $i -eq $(( num_threads - 1 )) ]; then
            end=$(( content_length - 1 ))
        fi
        local expected_len=$(( end - start + 1 ))
        local chunk_file="${DOWNLOAD_CHUNK_DIR}/chunk_$(printf "%02d" $i)"

        download_single_chunk "${url}" "${chunk_file}" "${start}" "${end}" "${expected_len}" &
        PARALLEL_PIDS+=($!)
    done

    # 动态实时进度条与实时网速刷新循环
    local last_bytes=0
    local last_time=$(date +%s)

    while true; do
        sleep 1
        local now=$(date +%s)
        local current_bytes=0
        for cf in "${DOWNLOAD_CHUNK_DIR}"/chunk_*; do
            if [ -f "$cf" ]; then
                local sz
                sz=$(stat -c%s "$cf" 2>/dev/null || stat -f%z "$cf" 2>/dev/null || echo 0)
                current_bytes=$(( current_bytes + sz ))
            fi
        done

        local time_diff=$(( now - last_time ))
        if [ $time_diff -le 0 ]; then time_diff=1; fi
        local bytes_diff=$(( current_bytes - last_bytes ))
        if [ $bytes_diff -lt 0 ]; then bytes_diff=0; fi

        local speed_bps=$(( bytes_diff / time_diff ))
        local speed_mbps=$(awk -v b="$speed_bps" 'BEGIN {printf "%.2f", b/1048576}')

        local downloaded_mb=$(( current_bytes / 1048576 ))
        local percent=0
        if [ "$content_length" -gt 0 ]; then
            percent=$(( current_bytes * 100 / content_length ))
            if [ "$percent" -gt 100 ]; then percent=100; fi
        fi

        # 估算剩余时间 (ETA)
        local eta_str="--:--"
        if [ "$speed_bps" -gt 0 ]; then
            local remaining_bytes=$(( content_length - current_bytes ))
            if [ "$remaining_bytes" -gt 0 ]; then
                local eta_secs=$(( remaining_bytes / speed_bps ))
                local eta_min=$(( eta_secs / 60 ))
                local eta_sec=$(( eta_secs % 60 ))
                eta_str=$(printf "%02d:%02d" $eta_min $eta_sec)
            else
                eta_str="00:00"
            fi
        fi

        local num_hashes=$(( percent / 4 ))
        local hash_str=""
        for ((h=0; h<num_hashes; h++)); do hash_str="${hash_str}#"; done

        printf "\r${GREEN}[INFO] 下载进度: [%-25s] %3d%% (%dMB/%dMB) | 实时网速: %6s MB/s | ETA: %s${NC}" \
            "$hash_str" "$percent" "$downloaded_mb" "$total_mb" "$speed_mbps" "$eta_str"

        last_bytes=$current_bytes
        last_time=$now

        local running=0
        for pid in "${PARALLEL_PIDS[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                running=1
                break
            fi
        done
        if [ $running -eq 0 ]; then
            printf "\n"
            break
        fi
    done

    # 等待第一轮分片任务完成
    local failed=0
    for pid in "${PARALLEL_PIDS[@]}"; do
        wait "$pid" || failed=$(( failed + 1 ))
    done
    PARALLEL_PIDS=()

    # 单分片精准二次重试回路：只对未下载完整的个别分片进行重试
    for ((i=0; i<num_threads; i++)); do
        local start=$(( i * chunk_size ))
        local end=$(( (i + 1) * chunk_size - 1 ))
        if [ $i -eq $(( num_threads - 1 )) ]; then
            end=$(( content_length - 1 ))
        fi
        local expected_len=$(( end - start + 1 ))
        local chunk_file="${DOWNLOAD_CHUNK_DIR}/chunk_$(printf "%02d" $i)"

        local cur_sz
        cur_sz=$(stat -c%s "${chunk_file}" 2>/dev/null || stat -f%z "${chunk_file}" 2>/dev/null || echo 0)
        if [ "$cur_sz" -ne "$expected_len" ]; then
            log_warn "分片 $(printf "%02d" $i) 尺寸校验不一致 (${cur_sz}/${expected_len})，单独发起二次重传..."
            rm -f "${chunk_file}"
            if ! download_single_chunk "${url}" "${chunk_file}" "${start}" "${end}" "${expected_len}"; then
                log_warn "分片 $(printf "%02d" $i) 二次重传失败。"
                rm -rf "${DOWNLOAD_CHUNK_DIR}"
                DOWNLOAD_CHUNK_DIR=""
                return 1
            fi
        fi
    done

    # 边拼边删流式整合：避免占用双倍磁盘空间（额外峰值仅单个分块大小约 110MB）
    log_info "所有 ${num_threads} 个分片校验一致，执行边拼边删流式整合成安装包..."
    > "${output}"
    for ((i=0; i<num_threads; i++)); do
        local chunk_file="${DOWNLOAD_CHUNK_DIR}/chunk_$(printf "%02d" $i)"
        cat "${chunk_file}" >> "${output}"
        rm -f "${chunk_file}"
    done

    rm -rf "${DOWNLOAD_CHUNK_DIR}"
    DOWNLOAD_CHUNK_DIR=""
    return 0
}

# 优先检查当前执行目录是否存在有效安装包
ORIGIN_PWD="${OLDPWD:-$PWD}"
if [ -f "${ORIGIN_PWD}/${TAR_FILE}" ] && check_package_integrity "${ORIGIN_PWD}/${TAR_FILE}"; then
    log_info "检测到执行目录已有完整安装包 ${TAR_FILE}，直接复用。"
    cp -f "${ORIGIN_PWD}/${TAR_FILE}" "${TAR_FILE}"
fi

if check_package_integrity "${TAR_FILE}"; then
    log_info "检测到本地已有完整且校验无误的安装包 ${TAR_FILE}，跳过下载步骤。"
else
    if [ -f "${TAR_FILE}" ]; then
        log_warn "检测到本地安装包不完整（可能因上次中断），清除旧文件准备极速重下..."
        rm -f "${TAR_FILE}"
    fi

    OFFICIAL_URLS=(
        "https://cdn.mysql.com/Downloads/MySQL-8.0/${TAR_FILE}"
        "https://dev.mysql.com/get/Downloads/MySQL-8.0/${TAR_FILE}"
    )

    DOWNLOAD_SUCCESS=0

    # 优先执行内建 8 线程 Curl 原生分块并发传输
    for URL in "${OFFICIAL_URLS[@]}"; do
        parallel_curl_download "${URL}" "${TAR_FILE}"
        download_ret=$?
        if [ $download_ret -eq 0 ]; then
            if check_package_integrity "${TAR_FILE}"; then
                log_info "恭喜！使用 8 并发分块传输成功完成极速下载，并通过完整性校验！"
                DOWNLOAD_SUCCESS=1
                break
            fi
        elif [ $download_ret -eq 2 ]; then
            # 不支持 Range，无需在其他官方镜像上反复重试并发分片，直接转单线程断点续传
            break
        fi
    done

    # 兜底单线程断点续传模式
    if [ "$DOWNLOAD_SUCCESS" -ne 1 ]; then
        log_warn "分块传输未完成或不支持 Range，转入原生断点续传模式..."
        for URL in "${OFFICIAL_URLS[@]}"; do
            log_info "下载节点: ${URL}"
            dl_ok=0
            if command -v curl >/dev/null 2>&1; then
                curl -L -A "${UA}" -C - --connect-timeout 20 --retry 3 --retry-delay 2 "${URL}" -o "${TAR_FILE}" && dl_ok=1 || dl_ok=0
            elif command -v wget >/dev/null 2>&1; then
                wget -c --timeout=30 --tries=3 "${URL}" -O "${TAR_FILE}" && dl_ok=1 || dl_ok=0
            fi

            if [ $dl_ok -eq 1 ] && check_package_integrity "${TAR_FILE}"; then
                log_info "单线程下载完成并通过完整性校验！"
                DOWNLOAD_SUCCESS=1
                break
            else
                log_warn "校验未通过，清理未完成文件并尝试下一个节点..."
                rm -f "${TAR_FILE}"
            fi
        done
    fi

    if [ "$DOWNLOAD_SUCCESS" -ne 1 ]; then
        log_err "所有下载节点均未响应，请检查服务器网络带宽！"
        exit 1
    fi
fi

log_info "正在解压并部署至路径 ${BASE_DIR} ..."
mkdir -p "${BASE_DIR}"
tar -xf "${TAR_FILE}" --strip-components=1 -C "${BASE_DIR}"

# 赋予必要可执行权限，防止 Systemd 或子命令因 umask 导致执行权限缺失
chmod +x "${BASE_DIR}/bin/"* 2>/dev/null || true
chmod +x "${BASE_DIR}/support-files/mysql.server" 2>/dev/null || true

# 解压完成后清理下载目录以释放磁盘空间
log_info "安装包解压完成，清理临时下载目录以释放磁盘空间..."
cd "${BASE_DIR}"
rm -rf "${TMP_DOWNLOAD_DIR}"
TMP_DOWNLOAD_DIR=""

mkdir -p "${DATA_DIR}"
mkdir -p "${LOG_DIR}"

# 安全检查：如果数据目录已存在且非空，必须由用户显式确认才可继续覆盖
if [ -d "${DATA_DIR}" ] && [ -n "$(ls -A "${DATA_DIR}" 2>/dev/null)" ]; then
    log_warn "=========================================================================="
    log_warn "【高危警告】检测到数据存储目录 ${DATA_DIR} 已存在且包含数据文件！"
    log_warn "继续执行将清空该目录下的所有旧数据并重新初始化数据库！"
    log_warn "=========================================================================="
    read -p "请确认是否覆盖并清空现有数据？(输入 'yes' 继续，输入其他任意内容安全退出): " CONFIRM_OVERWRITE
    if [ "${CONFIRM_OVERWRITE}" != "yes" ]; then
        log_err "用户取消操作，部署已安全终止，未改动任何现有数据。"
        exit 1
    fi
    log_warn "已获取用户授权，正在清空数据存储目录..."
fi

# 清理可能残留的旧数据与日志
rm -rf "${DATA_DIR:?}"/*
rm -rf "${LOG_DIR:?}"/*

chown -R ${MYSQL_USER}:${MYSQL_GROUP} "${BASE_DIR}"

# ------------------------------------------------------------------------------
# 9. 写入生产调优版 /etc/my.cnf 配置文件
# ------------------------------------------------------------------------------
log_step "Step 6: 生成生产级配置文件 /etc/my.cnf"

if [ -f /etc/my.cnf ]; then
    cp /etc/my.cnf /etc/my.cnf.bak.$(date +%Y%m%d%H%M%S)
fi

cat > /etc/my.cnf <<EOF
[client]
port = ${PORT}
socket = /tmp/mysql.sock
default-character-set = utf8mb4

[mysql]
default-character-set = utf8mb4
prompt = "\\u@\\h : \\d \\r:\\m:\\s> "

[mysqld]
# ==================== 基础配置 ====================
port = ${PORT}
user = ${MYSQL_USER}
socket = /tmp/mysql.sock
basedir = ${INSTALL_DIR}
datadir = ${DATA_DIR}
log-error = ${LOG_DIR}/mysql.log
pid-file = ${LOG_DIR}/mysql.pid

# ==================== 字符集配置 ====================
character-set-server = utf8mb4
collation-server = utf8mb4_general_ci
init_connect = 'SET NAMES utf8mb4'

# ==================== 网络和连接配置 ====================
max_allowed_packet = 1G
replica_max_allowed_packet = 1G
net_buffer_length = 16K
max_connections = ${MAX_CONNECTIONS}
max_connect_errors = 1000
connect_timeout = 60
wait_timeout = 600
interactive_timeout = 600
net_read_timeout = 120
net_write_timeout = 120
open_files_limit = 65535

# ==================== 服务器ID和复制 ====================
server-id = 1
log-bin = ${LOG_DIR}/mysql-bin
log_bin_index = ${LOG_DIR}/binlog.index
binlog_expire_logs_seconds = 864000
max_binlog_size = 500M
sync_binlog = 1
binlog_cache_size = ${BINLOG_CACHE_SIZE}
binlog_rows_query_log_events = OFF
relay_log = ${LOG_DIR}/mysql-relay
relay_log_index = ${LOG_DIR}/mysql-relay.index
relay_log_recovery = ON
relay_log_space_limit = 20G

# GTID配置
gtid_mode = ON
enforce_gtid_consistency = ON

# ==================== InnoDB配置 ====================
default_storage_engine = InnoDB
innodb_data_home_dir = ${DATA_DIR}
innodb_log_group_home_dir = ${DATA_DIR}
innodb_data_file_path = ibdata1:10M:autoextend
innodb_buffer_pool_size = ${BUFFER_POOL_SIZE}
innodb_redo_log_capacity = 2G
innodb_log_buffer_size = ${INNODB_LOG_BUFFER_SIZE}
innodb_flush_log_at_trx_commit = 1
innodb_flush_method = O_DIRECT
innodb_file_per_table = ON
innodb_buffer_pool_instances = ${BUFFER_POOL_INSTANCES}
innodb_online_alter_log_max_size = 2G
innodb_lock_wait_timeout = 50
innodb_strict_mode = 0
innodb_default_row_format = DYNAMIC
transaction_isolation = READ-COMMITTED
innodb_autoinc_lock_mode = 2
innodb_flush_neighbors = 0
innodb_page_cleaners = 4
innodb_purge_threads = 4
innodb_read_io_threads = 8
innodb_write_io_threads = 8
innodb_sort_buffer_size = ${INNODB_SORT_BUFFER_SIZE}

# ==================== 安全与认证 ====================
default_authentication_plugin = mysql_native_password
skip_name_resolve = ON
local_infile = OFF

# ==================== SQL模式 ====================
sql_mode = STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION

# ==================== 其他重要配置 ====================
lower_case_table_names = 1
autocommit = 1
explicit_defaults_for_timestamp = 1
log_timestamps = SYSTEM
log_bin_trust_function_creators = 1
read_only = 0
super_read_only = 0
skip_external_locking = ON
table_open_cache = ${TABLE_OPEN_CACHE}
table_definition_cache = ${TABLE_DEFINITION_CACHE}
table_open_cache_instances = 16
back_log = 3000
thread_cache_size = 100
thread_handling = one-thread-per-connection
tmp_table_size = ${TMP_TABLE_SIZE}
max_heap_table_size = ${MAX_HEAP_TABLE_SIZE}
sort_buffer_size = ${SORT_BUFFER_SIZE}
join_buffer_size = ${JOIN_BUFFER_SIZE}
read_buffer_size = ${READ_BUFFER_SIZE}
read_rnd_buffer_size = ${READ_RND_BUFFER_SIZE}
bulk_insert_buffer_size = ${BULK_INSERT_BUFFER_SIZE}
performance_schema = ${PERFORMANCE_SCHEMA}
performance_schema_max_table_instances = 10000
performance_schema_max_sql_text_length = 4096

# ==================== 错误日志和慢查询 ====================
slow_query_log = ON
slow_query_log_file = ${LOG_DIR}/mysql-slow.log
long_query_time = 2
log_queries_not_using_indexes = OFF
log_throttle_queries_not_using_indexes = 10
min_examined_row_limit = 100
log_slow_admin_statements = ON
log_slow_replica_statements = ON

[mysqldump]
quick
max_allowed_packet = 16M

[myisamchk]
key_buffer_size = 256M
sort_buffer_size = 4M
read_buffer = 2M
write_buffer = 2M

[mysqlhotcopy]
interactive-timeout
EOF

log_info "配置文件 /etc/my.cnf 生成成功！"

# ------------------------------------------------------------------------------
# 10. 初始化数据库 (带 --lower-case-table-names=1 与 --console 探针)
# ------------------------------------------------------------------------------
log_step "Step 7: 初始化数据库"

INIT_LOG="/tmp/mysql_init_$$.log"
touch "${INIT_LOG}"
chmod 600 "${INIT_LOG}"
log_info "正在执行 mysqld --initialize ..."

set +e
"${INSTALL_DIR}/bin/mysqld" \
    --defaults-file=/etc/my.cnf \
    --initialize \
    --console \
    --lower-case-table-names=1 \
    --user=${MYSQL_USER} > "${INIT_LOG}" 2>&1
INIT_RET=$?
set -e

TEMP_PASSWORD=$(grep "A temporary password" "${INIT_LOG}" "${LOG_DIR}/mysql.log" 2>/dev/null | awk '{print $NF}' | tail -n 1 || true)

if [ -n "${TEMP_PASSWORD}" ] && [ $INIT_RET -eq 0 ]; then
    log_info "数据库初始化成功！"
    rm -f "${INIT_LOG}" 2>/dev/null || true
    INIT_LOG=""
else
    log_err "数据库初始化失败！详情见以下日志输出:"
    echo "--------------------------------------------------------------------------"
    if [ -s "${INIT_LOG}" ]; then
        cat "${INIT_LOG}"
    elif [ -s "${LOG_DIR}/mysql.log" ]; then
        cat "${LOG_DIR}/mysql.log"
    else
        echo "未能在控制台或 ${LOG_DIR}/mysql.log 中捕获到初始化错误信息。"
    fi
    echo "--------------------------------------------------------------------------"
    exit 1
fi

# ------------------------------------------------------------------------------
# 11. 配置环境变量、Systemd 服务与防火墙自动放行
# ------------------------------------------------------------------------------
log_step "Step 8: 配置环境变量、注册服务与防火墙端口放行"

PATH_FILE="/etc/profile.d/mysql.sh"
cat > "${PATH_FILE}" <<EOF
export PATH=\${PATH}:${INSTALL_DIR}/bin
EOF
source "${PATH_FILE}" || true

ln -sf ${INSTALL_DIR}/bin/mysql /usr/bin/mysql 2>/dev/null || true
ln -sf ${INSTALL_DIR}/bin/mysqladmin /usr/bin/mysqladmin 2>/dev/null || true

SERVICE_FILE="/etc/systemd/system/mysqld.service"
cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=MySQL Server 8.0.46
After=network.target
After=syslog.target

[Service]
User=${MYSQL_USER}
Group=${MYSQL_GROUP}
Type=forking
ExecStart=${INSTALL_DIR}/support-files/mysql.server start
ExecStop=${INSTALL_DIR}/support-files/mysql.server stop
ExecReload=${INSTALL_DIR}/support-files/mysql.server restart
PrivateTmp=false
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable mysqld >/dev/null 2>&1
systemctl start mysqld

if ! systemctl is-active --quiet mysqld; then
    log_err "MySQL 服务启动异常，请检查 systemctl status mysqld！"
    exit 1
fi

# 防火墙端口全自动放行支持 (firewalld / ufw)
log_info "自动检测并放行防火墙端口 ${PORT} ..."
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port=${PORT}/tcp >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    log_info "firewalld 防火墙端口 ${PORT} 已放行。"
elif command -v ufw >/dev/null 2>&1 && ufw status | grep -q "active"; then
    ufw allow ${PORT}/tcp >/dev/null 2>&1 || true
    log_info "ufw 防火墙端口 ${PORT} 已放行。"
fi

# ------------------------------------------------------------------------------
# 12. Socket 就绪轮询与修改 root 密码及远程权限
# ------------------------------------------------------------------------------
log_step "Step 9: Socket 就绪轮询、修改 root 密码并开启外部远程访问"

log_info "等待 MySQL 监听 Socket (/tmp/mysql.sock) 准备就绪..."
SOCKET_READY=0
for ((i=1; i<=30; i++)); do
    if [ -S /tmp/mysql.sock ] && "${INSTALL_DIR}/bin/mysql" --connect-expired-password -u root -p"${TEMP_PASSWORD}" -S /tmp/mysql.sock -e "SELECT 1;" >/dev/null 2>&1; then
        SOCKET_READY=1
        break
    fi
    sleep 1
done

if [ $SOCKET_READY -ne 1 ]; then
    log_warn "Socket 轮询等待超时，尝试直接执行连接修改..."
else
    log_info "MySQL 监听 Socket 就绪并验证连接成功！"
fi

# 严格生成符合 MySQL 8.0 复杂性策略的 12 位高强度密码（含大写、小写、数字、特殊符号）
generate_random_password() {
    local uppers="ABCDEFGHJKLMNPQRSTUVWXYZ"
    local lowers="abcdefghijkmnpqrstuvwxyz"
    local digits="23456789"
    local specials="@#%&_"
    
    local p1
    local p2
    local p3
    local p4
    p1=$(tr -dc "${uppers}" < /dev/urandom 2>/dev/null | head -c 3 || echo "ABC")
    p2=$(tr -dc "${lowers}" < /dev/urandom 2>/dev/null | head -c 3 || echo "xyz")
    p3=$(tr -dc "${digits}" < /dev/urandom 2>/dev/null | head -c 3 || echo "888")
    p4=$(tr -dc "${specials}" < /dev/urandom 2>/dev/null | head -c 3 || echo "@#_")
    
    local combined="${p1}${p2}${p3}${p4}"
    if command -v shuf >/dev/null 2>&1; then
        echo "${combined}" | fold -w1 | shuf | tr -d '\n'
    else
        echo "${combined}"
    fi
}

FINAL_ROOT_PASS=$(generate_random_password)

PASS_UPDATE_LOG="/tmp/mysql_pass_update_$$.log"
touch "${PASS_UPDATE_LOG}"
chmod 600 "${PASS_UPDATE_LOG}"

set +e
${INSTALL_DIR}/bin/mysql --connect-expired-password -u root -p"${TEMP_PASSWORD}" -S /tmp/mysql.sock <<EOF > "${PASS_UPDATE_LOG}" 2>&1
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${FINAL_ROOT_PASS}';
CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED WITH mysql_native_password BY '${FINAL_ROOT_PASS}';
ALTER USER 'root'@'%' IDENTIFIED WITH mysql_native_password BY '${FINAL_ROOT_PASS}';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF
PASS_RET=$?
set -e

if [ $PASS_RET -eq 0 ]; then
    log_info "root 密码更新及外部远程访问 ('root'@'%') 设置成功！"
    rm -f "${PASS_UPDATE_LOG}" 2>/dev/null || true
    PASS_UPDATE_LOG=""
else
    log_err "配置 root 密码或远程访问失败！报错日志如下 (${PASS_UPDATE_LOG}):"
    echo "--------------------------------------------------------------------------"
    cat "${PASS_UPDATE_LOG}" 2>/dev/null || true
    echo "--------------------------------------------------------------------------"
    exit 1
fi

# ------------------------------------------------------------------------------
# 13. 完成输出
# ------------------------------------------------------------------------------
log_step "部署完成！"

echo -e "${GREEN}"
echo "=========================================================================="
echo "          MySQL ${MYSQL_VERSION} 生产级自动化部署完成！"
echo "=========================================================================="
echo -e "${NC}"
echo "部署主目录: ${BASE_DIR}"
echo "数据目录: ${DATA_DIR}"
echo "日志目录: ${LOG_DIR}"
echo "配置文件: /etc/my.cnf"
echo "服务端口: ${PORT}"
echo "部署模式: ${DEPLOY_MODE_NAME}"
echo "分配 Buffer Pool: ${BUFFER_POOL_SIZE} (Instances: ${BUFFER_POOL_INSTANCES})"
echo "Performance Schema: ${PERFORMANCE_SCHEMA}"
echo "最大连接数: ${MAX_CONNECTIONS}"
echo "外部访问: 已开启 ('root'@'%')"
echo ""
echo -e "${YELLOW}【重要】自动生成的 12 位 root 随机密码为:${NC} ${GREEN}${FINAL_ROOT_PASS}${NC}"
echo ""
echo "本地登录测试指令:"
echo -e "  ${BLUE}mysql -u root -p'${FINAL_ROOT_PASS}' -P ${PORT}${NC}"
echo ""
echo "远程登录连接指令:"
echo -e "  ${BLUE}mysql -h <服务器IP> -P ${PORT} -u root -p'${FINAL_ROOT_PASS}'${NC}"
echo "=========================================================================="
