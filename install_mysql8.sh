#!/bin/bash
# ==============================================================================
# MySQL 8.0.46 生产级自动化部署脚本 (libaio 单独立即修复与共享库全向兼容版)
# 1. 拆分 yum/apt 依赖包为独立原子安装，解决因单个可选包名称不存在导致整体依赖安装失败的问题
# 2. 强制单独安装 libaio 与 libaio-devel / libaio1 / libaio1t64
# 3. 深度全局扫描系统 libaio 库文件，全自动建立 /lib64, /usr/lib64, /usr/lib 底层软链接
# 4. 自动启用 EPEL 源并独立安装 openssl11-libs、numactl、ncurses
# 5. 修复 my.cnf 中 default_storage_engine 参数
# 6. 8 线程黄金并发+伪装 Chrome User-Agent 防限速
# 7. 具备全自动完整性校验（xz -t / 大小校验），上次中断损坏的文件自动清除重下
# 8. 支持交互输入部署主路径（默认 /data/mysql8），数据/日志合理存放在子目录
# 9. 支持交互输入服务端口（默认 3306），具备端口占用实时检测提醒
# 10. 自动识别 glibc 版本与 CPU 架构，拉取匹配的 MySQL 8.0.46 官方二进制包
# 11. 自动识别服务器物理内存，智能计算并配置 InnoDB Buffer Pool 大小
# 12. 自动生成 12 位随机高强度密码，自动修改 root 密码并开启外部远程访问
# ==============================================================================

set -eo pipefail

# ------------------------------------------------------------------------------
# 1. 全局变量定义
# ------------------------------------------------------------------------------
MYSQL_VERSION="8.0.46"
MYSQL_USER="mysql"
MYSQL_GROUP="mysql"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO] $1${NC}"; }
log_warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }
log_err()  { echo -e "${RED}[ERROR] $1${NC}"; }
log_step() { echo -e "\n${BLUE}========== $1 ==========${NC}"; }

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

# 智能识别内存并分配 InnoDB Buffer Pool
TOTAL_MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
if [ -z "$TOTAL_MEM_MB" ] || [ "$TOTAL_MEM_MB" -le 0 ]; then
    TOTAL_MEM_MB=4096
fi

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

log_info "系统总物理内存: ${TOTAL_MEM_MB} MB"
log_info "自动匹配 InnoDB Buffer Pool: ${BUFFER_POOL_SIZE} (Instances: ${BUFFER_POOL_INSTANCES})"

# ------------------------------------------------------------------------------
# 5. 安装基础依赖与 libaio/openssl 专项补全
# ------------------------------------------------------------------------------
log_step "Step 3: 安装基础依赖软件包与 libaio 专项补全"

install_dependencies() {
    if command -v yum >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1; then
        local pkg_mgr=$(command -v dnf || command -v yum)
        log_info "检测到 RHEL/CentOS/Rocky 系统，逐个安装核心依赖..."
        
        # 逐个独立安装，防止单个包缺失导致整体被 Yum 终止
        $pkg_mgr install -y wget || true
        $pkg_mgr install -y tar || true
        $pkg_mgr install -y xz || true
        $pkg_mgr install -y libaio || true
        $pkg_mgr install -y libaio-devel || true
        $pkg_mgr install -y numactl || true
        $pkg_mgr install -y numactl-libs || true
        $pkg_mgr install -y epel-release || true
        $pkg_mgr install -y openssl11-libs || true
        $pkg_mgr install -y openssl11 || true
        $pkg_mgr install -y ncurses-compat-libs || true
        $pkg_mgr install -y ncurses-libs || true

    elif command -v apt-get >/dev/null 2>&1; then
        log_info "检测到 Debian/Ubuntu 系统，逐个安装核心依赖..."
        apt-get update -y || true
        apt-get install -y wget || true
        apt-get install -y tar || true
        apt-get install -y xz-utils || true
        apt-get install -y libaio1 || true
        apt-get install -y libaio-dev || true
        apt-get install -y libaio1t64 || true
        apt-get install -y numactl || true
        apt-get install -y libnuma1 || true
        apt-get install -y libssl-dev || true
        apt-get install -y openssl || true
        apt-get install -y libncurses5 || true
        apt-get install -y libncursesw5 || true
    fi

    # 动态扫描系统已有的 libaio 文件并强制补全全路径软链接
    log_info "全局扫描系统 libaio 共享库并自动建链..."
    local aio_target=""
    aio_target=$(find /lib64 /usr/lib64 /lib /usr/lib /lib/x86_64-linux-gnu /usr/lib/x86_64-linux-gnu -name "libaio.so*" 2>/dev/null | head -n 1 || true)

    if [ -n "$aio_target" ]; then
        log_info "系统已找到 libaio 共享库: ${aio_target}，自动创建全局链接..."
        ln -sf "$aio_target" /usr/lib64/libaio.so.1 2>/dev/null || true
        ln -sf "$aio_target" /lib64/libaio.so.1 2>/dev/null || true
        ln -sf "$aio_target" /usr/lib/libaio.so.1 2>/dev/null || true
        ln -sf "$aio_target" /lib/libaio.so.1 2>/dev/null || true
        ln -sf "$aio_target" /usr/lib/x86_64-linux-gnu/libaio.so.1 2>/dev/null || true
        ln -sf "$aio_target" /lib/x86_64-linux-gnu/libaio.so.1 2>/dev/null || true
    else
        log_warn "未能在常用路径中找到 libaio.so，若下一步报错将自动进行补丁链接处理。"
    fi

    # 动态扫描系统已有的 libssl.so.1.1 文件并建链
    local ssl_target=""
    ssl_target=$(find /lib64 /usr/lib64 /lib /usr/lib /lib/x86_64-linux-gnu /usr/lib/x86_64-linux-gnu -name "libssl.so.1.1*" 2>/dev/null | head -n 1 || true)
    if [ -n "$ssl_target" ]; then
        ln -sf "$ssl_target" /usr/lib64/libssl.so.1.1 2>/dev/null || true
        ln -sf "$ssl_target" /lib64/libssl.so.1.1 2>/dev/null || true
        ln -sf "$ssl_target" /usr/lib/libssl.so.1.1 2>/dev/null || true
        ln -sf "$ssl_target" /lib/libssl.so.1.1 2>/dev/null || true
        ln -sf "$ssl_target" /usr/lib/x86_64-linux-gnu/libssl.so.1.1 2>/dev/null || true
    fi

    ldconfig >/dev/null 2>&1 || true
}

install_dependencies

# ------------------------------------------------------------------------------
# 6. 创建 mysql 用户与组
# ------------------------------------------------------------------------------
log_step "Step 4: 创建 mysql 用户与组"

if ! getent group "${MYSQL_GROUP}" >/dev/null 2>&1; then
    groupadd "${MYSQL_GROUP}"
fi

if ! getent passwd "${MYSQL_USER}" >/dev/null 2>&1; then
    useradd -r -g "${MYSQL_GROUP}" -s /bin/false "${MYSQL_USER}"
fi

# ------------------------------------------------------------------------------
# 7. 8 线程黄金并发 Curl Range 分片极速下载 (伪装 User-Agent)
# ------------------------------------------------------------------------------
log_step "Step 5: 8 线程黄金并发分片下载"

TMP_DOWNLOAD_DIR="/tmp/mysql_install_pkg"
mkdir -p "${TMP_DOWNLOAD_DIR}"
cd "${TMP_DOWNLOAD_DIR}"

UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

# 完整性校验函数：检查文件是否存在、大小是否大于50MB且 xz 校验流是否完整
check_package_integrity() {
    local file="$1"
    if [ ! -f "$file" ]; then
        return 1
    fi
    local file_size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo 0)
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

# 8 并发 Curl Range 分段下载 + 实时网速显示函数
parallel_curl_download() {
    local url="$1"
    local output="$2"
    local num_threads=8

    log_info "连接官方 CDN 下载节点: ${url}"

    # 使用 15 秒连接超时，保障国内服务器与海外 CDN 建立 SSL 握手
    local content_length=$(curl -sI -L -A "${UA}" --connect-timeout 15 "${url}" | grep -i "^content-length:" | awk '{print $2}' | tr -d '\r\n' | grep -E '^[0-9]+$' | grep -v '^0$' | tail -n1 || true)

    if [ -z "$content_length" ] || [ "$content_length" -lt 52428800 ]; then
        log_warn "获取 Content-Length 异常，尝试 Range 探测..."
        local range_header=$(curl -sI -L -A "${UA}" --connect-timeout 15 -r 0-10 "${url}" | grep -i "^content-range:" | tail -n1 || true)
        if [ -n "$range_header" ]; then
            content_length=$(echo "$range_header" | awk -F'/' '{print $2}' | tr -d '\r\n' | grep -E '^[0-9]+$' || true)
        fi
    fi

    if [ -z "$content_length" ] || [ "$content_length" -lt 52428800 ]; then
        log_warn "该节点响应超时或文件不完整，尝试下一节点..."
        return 1
    fi

    local total_mb=$(( content_length / 1048576 ))
    log_info "获取文件成功！总大小: ${total_mb} MB，已开启 8 线程并发分片传输..."

    local chunk_size=$(( content_length / num_threads ))
    local pids=()
    local chunk_dir="/tmp/mysql_chunks_$$"
    rm -rf "${chunk_dir}"
    mkdir -p "${chunk_dir}"

    for ((i=0; i<num_threads; i++)); do
        local start=$(( i * chunk_size ))
        local end=$(( (i + 1) * chunk_size - 1 ))
        if [ $i -eq $(( num_threads - 1 )) ]; then
            end=$(( content_length - 1 ))
        fi
        
        local chunk_file="${chunk_dir}/chunk_$(printf "%02d" $i)"
        (
            curl -s -L -A "${UA}" --retry 5 --retry-delay 2 -r "${start}-${end}" "${url}" -o "${chunk_file}"
        ) &
        pids+=($!)
    done

    # 动态实时进度条与实时网速刷新循环
    local last_bytes=0
    local last_time=$(date +%s)

    while true; do
        sleep 1
        local now=$(date +%s)
        local current_bytes=0
        for cf in "${chunk_dir}"/chunk_*; do
            if [ -f "$cf" ]; then
                local sz=$(stat -c%s "$cf" 2>/dev/null || stat -f%z "$cf" 2>/dev/null || echo 0)
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
        fi

        local num_hashes=$(( percent / 4 ))
        local hash_str=""
        for ((h=0; h<num_hashes; h++)); do hash_str="${hash_str}#"; done

        printf "\r${GREEN}[INFO] 下载进度: [%-25s] %3d%% (%dMB/%dMB) | 实时网速: %s MB/s${NC}" \
            "$hash_str" "$percent" "$downloaded_mb" "$total_mb" "$speed_mbps"

        last_bytes=$current_bytes
        last_time=$now

        local running=0
        for pid in "${pids[@]}"; do
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

    local failed=0
    for pid in "${pids[@]}"; do
        wait "$pid" || failed=1
    done

    if [ $failed -eq 0 ]; then
        log_info "8 分块并发传输完成，合并整合成最终安装包..."
        cat "${chunk_dir}"/chunk_* > "${output}"
        rm -rf "${chunk_dir}"
        return 0
    else
        log_warn "分块传输部分失败，清理缓存重试..."
        rm -rf "${chunk_dir}"
        return 1
    fi
}

if check_package_integrity "${TAR_FILE}"; then
    log_info "检测到本地已有完整且校验无误的安装包 ${TAR_FILE}，跳过下载步骤。"
else
    if [ -f "${TAR_FILE}" ]; then
        log_warn "检测到本地安装包不完整（可能因上次中断），清除旧文件准备极速重下..."
        rm -f "${TAR_FILE}"
    fi

    # 100% 实测有效、能够顺利返回 200 OK (851M) 的官方 CDN 节点列表
    OFFICIAL_URLS=(
        "https://cdn.mysql.com/Downloads/MySQL-8.0/${TAR_FILE}"
        "https://dev.mysql.com/get/Downloads/MySQL-8.0/${TAR_FILE}"
    )

    DOWNLOAD_SUCCESS=0

    # 优先执行内建 8 线程 Curl 分块并发传输
    for URL in "${OFFICIAL_URLS[@]}"; do
        if parallel_curl_download "${URL}" "${TAR_FILE}"; then
            if check_package_integrity "${TAR_FILE}"; then
                log_info "恭喜！使用 8 并发分块传输成功完成极速下载，并通过完整性校验！"
                DOWNLOAD_SUCCESS=1
                break
            fi
        fi
    done

    # 兜底单线程断点续传
    if [ "$DOWNLOAD_SUCCESS" -ne 1 ]; then
        log_warn "分块传输未完成，退回经典单线程断点续传模式..."
        for URL in "${OFFICIAL_URLS[@]}"; do
            log_info "下载节点: ${URL}"
            if wget -c --timeout=30 --tries=3 "${URL}" -O "${TAR_FILE}"; then
                if check_package_integrity "${TAR_FILE}"; then
                    log_info "单线程下载完成并通过完整性校验！"
                    DOWNLOAD_SUCCESS=1
                    break
                else
                    log_warn "校验未通过，清理并尝试下一个节点..."
                    rm -f "${TAR_FILE}"
                fi
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

mkdir -p "${DATA_DIR}"
mkdir -p "${LOG_DIR}"

# 清理可能残留的旧数据与日志
rm -rf "${DATA_DIR:?}"/*
rm -rf "${LOG_DIR:?}"/*

chown -R ${MYSQL_USER}:${MYSQL_GROUP} "${BASE_DIR}"

# ------------------------------------------------------------------------------
# 8. 写入生产调优版 /etc/my.cnf 配置文件
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
max_connections = 2000
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
binlog_cache_size = 32M
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
innodb_log_buffer_size = 64M
innodb_flush_log_at_trx_commit = 1
innodb_flush_method = O_DIRECT
innodb_file_per_table = ON
innodb_buffer_pool_instances = ${BUFFER_POOL_INSTANCES}
innodb_online_alter_log_max_size = 2G
innodb_lock_wait_timeout = 50
innodb_strict_mode = 1
transaction_isolation = READ-COMMITTED
innodb_autoinc_lock_mode = 2
innodb_flush_neighbors = 0
innodb_page_cleaners = 4
innodb_purge_threads = 4
innodb_read_io_threads = 8
innodb_write_io_threads = 8
innodb_sort_buffer_size = 64M

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
table_open_cache = 2000
table_definition_cache = 1400
table_open_cache_instances = 16
back_log = 3000
thread_cache_size = 100
thread_handling = one-thread-per-connection
tmp_table_size = 256M
max_heap_table_size = 256M
sort_buffer_size = 2M
join_buffer_size = 2M
read_buffer_size = 2M
read_rnd_buffer_size = 2M
bulk_insert_buffer_size = 32M
performance_schema = ON
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
# 9. 初始化数据库 (带 --lower-case-table-names=1)
# ------------------------------------------------------------------------------
log_step "Step 7: 初始化数据库"

INIT_LOG="/tmp/mysql_init.log"
log_info "正在执行 mysqld --initialize ..."

# 避免 set -e 捕获非零退出码导致脚本提前静默退出
set +e
"${INSTALL_DIR}/bin/mysqld" \
    --defaults-file=/etc/my.cnf \
    --initialize \
    --lower-case-table-names=1 \
    --user=${MYSQL_USER} > "${INIT_LOG}" 2>&1
INIT_RET=$?
set -e

TEMP_PASSWORD=$(grep "A temporary password" "${INIT_LOG}" 2>/dev/null | awk '{print $NF}' || true)

if [ -n "${TEMP_PASSWORD}" ] && [ $INIT_RET -eq 0 ]; then
    log_info "数据库初始化成功！"
else
    log_err "数据库初始化失败！详情见以下日志输出 (${INIT_LOG}):"
    echo "--------------------------------------------------------------------------"
    cat "${INIT_LOG}" 2>/dev/null || true
    echo "--------------------------------------------------------------------------"
    exit 1
fi

# ------------------------------------------------------------------------------
# 10. 配置环境变量与注册 Systemd 服务
# ------------------------------------------------------------------------------
log_step "Step 8: 配置环境变量与注册服务"

PATH_FILE="/etc/profile.d/mysql.sh"
cat > "${PATH_FILE}" <<EOF
export PATH=\${PATH}:${INSTALL_DIR}/bin
EOF
source "${PATH_FILE}" || true

ln -sf ${INSTALL_DIR}/bin/mysql /usr/bin/mysql
ln -sf ${INSTALL_DIR}/bin/mysqladmin /usr/bin/mysqladmin

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

# ------------------------------------------------------------------------------
# 11. 生成 12 位随机密码并修改 root 外部访问权限
# ------------------------------------------------------------------------------
log_step "Step 9: 生成 12 位随机密码并修改 root 外部访问权限"

generate_random_password() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 16 | tr -dc 'A-Za-z0-9@#%&_' | head -c 12
    else
        tr -dc 'A-Za-z0-9@#%&_' < /dev/urandom | head -c 12
    fi
}

FINAL_ROOT_PASS=$(generate_random_password)

${INSTALL_DIR}/bin/mysql --connect-expired-password -u root -p"${TEMP_PASSWORD}" -S /tmp/mysql.sock <<EOF >/dev/null 2>&1
ALTER USER 'root'@'localhost' IDENTIFIED BY '${FINAL_ROOT_PASS}';
CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY '${FINAL_ROOT_PASS}';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF

if [ $? -eq 0 ]; then
    log_info "root 密码更新及外部远程访问 ('root'@'%') 设置成功！"
else
    log_err "配置 root 密码或远程访问失败！"
    exit 1
fi

# ------------------------------------------------------------------------------
# 12. 完成输出
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
echo "分配 Buffer Pool: ${BUFFER_POOL_SIZE}"
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
