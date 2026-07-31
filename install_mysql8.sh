#!/bin/bash
# ==============================================================================
# MySQL 8.0.46 生产级自动化部署脚本 (带断点完整性强校验与双镜像极速版)
# 1. 具备全自动完整性校验（xz -t / 大小校验），上次中断损坏的文件自动清除重下
# 2. 内置华为云、腾讯云国内高带宽镜像源 + 官方 CDN 自动故障切源下载
# 3. 支持交互输入部署主路径（默认 /data/mysql8），数据/日志合理存放在子目录
# 4. 支持交互输入服务端口（默认 3306），具备端口占用实时检测提醒
# 5. 自动识别 glibc 版本与 CPU 架构，拉取匹配的 MySQL 8.0.46 官方二进制包
# 6. 自动识别服务器物理内存，智能计算并配置 InnoDB Buffer Pool 大小
# 7. 自动生成 12 位随机高强度密码，自动修改 root 密码并开启外部远程访问
# 8. 整合全面调优的 my.cnf，安全支持 lower_case_table_names=1 初始化
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
# 5. 安装依赖
# ------------------------------------------------------------------------------
log_step "Step 3: 安装依赖软件包"

if command -v yum >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER=$(command -v dnf || command -v yum)
    $PKG_MANAGER install -y wget tar xz libaio numactl-libs ncurses-compat-libs >/dev/null 2>&1 || \
    $PKG_MANAGER install -y wget tar xz libaio numactl >/dev/null 2>&1
elif command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1
    apt-get install -y wget tar xz-utils libaio1 numactl libncurses5 >/dev/null 2>&1 || \
    apt-get install -y wget tar xz-utils libaio-dev numactl >/dev/null 2>&1
fi

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
# 7. 极速下载、完整性校验与解压
# ------------------------------------------------------------------------------
log_step "Step 5: 极速下载与安装包完整性校验"

TMP_DOWNLOAD_DIR="/tmp/mysql_install_pkg"
mkdir -p "${TMP_DOWNLOAD_DIR}"
cd "${TMP_DOWNLOAD_DIR}"

# 校验函数：检查文件是否存在、大小是否大于50MB且 xz 校验流是否完整
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

if check_package_integrity "${TAR_FILE}"; then
    log_info "检测到本地已有完整且校验无误的安装包 ${TAR_FILE}，跳过下载步骤。"
else
    if [ -f "${TAR_FILE}" ]; then
        log_warn "检测到本地安装包不完整或损坏（可能因上次中断导致），清除旧文件重新下载..."
        rm -f "${TAR_FILE}"
    fi

    # 动态极速镜像源列表（自动尝试国内高带宽节点）
    MIRRORS=(
        "https://repo.huaweicloud.com/mysql/Downloads/MySQL-8.0"
        "https://mirrors.cloud.tencent.com/mysql/downloads/MySQL-8.0"
        "https://cdn.mysql.com/Downloads/MySQL-8.0"
        "https://downloads.mysql.com/Downloads/MySQL-8.0"
    )

    DOWNLOAD_SUCCESS=0
    for MIRROR_BASE in "${MIRRORS[@]}"; do
        URL="${MIRROR_BASE}/${TAR_FILE}"
        log_info "正在尝试下载节点: ${URL}"
        if wget -c --timeout=15 --tries=2 "${URL}" -O "${TAR_FILE}"; then
            if check_package_integrity "${TAR_FILE}"; then
                log_info "恭喜，成功从该镜像节点完成极速下载并通过完整性校验！"
                DOWNLOAD_SUCCESS=1
                break
            else
                log_warn "从该节点下载的文件未能通过完整性校验，清理并自动尝试下一个镜像..."
                rm -f "${TAR_FILE}"
            fi
        else
            log_warn "该镜像节点连接超时，自动尝试下一个镜像..."
            rm -f "${TAR_FILE}"
        fi
    done

    if [ "$DOWNLOAD_SUCCESS" -ne 1 ]; then
        log_err "所有镜像源均未能下载到完整无误的安装包，请检查网络！"
        exit 1
    fi
fi

log_info "正在解压并部署至路径 ${BASE_DIR} ..."
mkdir -p "${BASE_DIR}"
tar -xf "${TAR_FILE}" --strip-components=1 -C "${BASE_DIR}"

mkdir -p "${DATA_DIR}"
mkdir -p "${LOG_DIR}"

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

"${INSTALL_DIR}/bin/mysqld" \
    --defaults-file=/etc/my.cnf \
    --initialize \
    --lower-case-table-names=1 \
    --user=${MYSQL_USER} > "${INIT_LOG}" 2>&1

TEMP_PASSWORD=$(grep "A temporary password" "${INIT_LOG}" | awk '{print $NF}')

if [ -n "${TEMP_PASSWORD}" ]; then
    log_info "数据库初始化成功！"
else
    log_err "初始化失败，详情见日志: ${INIT_LOG}"
    cat "${INIT_LOG}"
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
