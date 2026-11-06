# mysql8-auto-deploy (MySQL 8.0.46 生产级自动化部署项目)

[![MySQL](https://img.shields.io/badge/MySQL-8.0.46-blue.svg)](https://www.mysql.com/)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Linux-lightgrey.svg)](https://www.kernel.org/)

一套专为 Linux 生产环境打造的 **MySQL 8.0.46 一键自动化部署脚本**。支持智能识别系统 `glibc` 版本与 CPU 架构，自动匹配拉取官方二进制包，并具备硬件资源智能计算、端口占用校验、12 位高强度随机密码生成及外部远程访问开箱即用能力。

---

## 🌟 核心特性

- 🧠 **glibc 与架构智能匹配**：自动检测系统 `glibc` 版本（区分 `glibc2.17` / `glibc2.28`）及 CPU 架构（`x86_64` / `aarch64`），拉取官方匹配包。
- ⚡ **原生极速分片下载**：内置 8 线程 Curl 原生并发分片传输与 HTTP 206 握手校验，支持单分片局部重试，采用“边拼边删”流式合并，大幅节省临时磁盘开销。
- 🎯 **生产 / 测试双环境适配**：支持“生产高性能模式”（全量缓存与监控）与“测试/轻量节能模式”（常驻内存仅 ~200MB，关闭 Performance Schema，精简会话缓存，防测试机 OOM）。
- ⚙️ **交互式路径与端口配置**：支持自定义部署主目录与服务端口，内置端口占用实时检测与二次提醒。
- 💾 **InnoDB 内存智能适配**：依据所选部署模式与系统总物理内存，动态计算分配最优的 `innodb_buffer_pool_size` 与参数组合。
- 🔒 **高安全性与防误删**：数据目录非空覆盖安全确认，敏感日志权限严格隔离（`chmod 600`），自动生成 12 位高强度随机密码并授权 `root@%` 远程访问。
- 🛠️ **生产级 my.cnf 优化**：统一 `utf8mb4` 字符集，修正 MySQL 8.0 `lower_case_table_names=1` 初始化陷阱，配置 `innodb_strict_mode=0` 彻底解决 Row size too large 问题。

---

## 🚀 快速开始

在 Linux 服务器终端执行以下一键安装命令（根据网络选择 **Gitee** 或 **GitHub** 镜像）：

### 选项 A：Gitee 镜像节点（推荐国内服务器）
```bash
wget -O install_mysql8.sh https://gitee.com/chiasong/mysql8-auto-deploy/raw/main/install_mysql8.sh && chmod +x install_mysql8.sh && sudo ./install_mysql8.sh
```

### 选项 B：GitHub 节点（推荐海外服务器）
```bash
wget -O install_mysql8.sh https://raw.githubusercontent.com/chiasong/mysql8-auto-deploy/main/install_mysql8.sh && chmod +x install_mysql8.sh && sudo ./install_mysql8.sh
```

---

## 📂 项目结构

```text
mysql8-auto-deploy/
├── install_mysql8.sh   # 核心一键部署脚本
├── my.cnf              # 生产环境调优版 MySQL 配置文件
├── README.md           # 项目使用说明文档
├── .gitignore          # Git 忽略规则文件
└── LICENSE             # MIT 开源许可证
```

---

## 🛠️ 安装流程与交互示例

启动脚本后将引导您进行交互设置：

1. **选择部署主路径**（默认 `/data/mysql8`）：
   - 程序目录：`/data/mysql8`
   - 数据目录：`/data/mysql8/datas`
   - 日志目录：`/data/mysql8/logs`
2. **选择部署运行模式**（默认 `1` 生产模式）：
   - `1) 生产高性能模式`：充分利用硬件资源，内存按 50%~60% 分配，启用 Performance Schema，最大 2000 连接。
   - `2) 测试/轻量节能模式`：关闭 Performance Schema，内存占用仅约 200MB，适合测试机、开发混跑机与低配 VPS。
3. **选择服务端口**（默认 `3306`）：自动校验 1-65535 端口有效性及是否被占用。
4. **自动化部署**：自动执行 8 线程并发分片下载、配置 `/etc/my.cnf`、初始化数据库、启动服务并生成 12 位 root 随机密码。

---

## 📄 运行模式与 my.cnf 关键参数对比

| 配置项 | 生产高性能模式 | 测试/轻量节能模式 | 说明 |
| :--- | :--- | :--- | :--- |
| **`performance_schema`** | `ON` | `OFF` | 测试模式关闭可立省 250MB~400MB 物理常驻内存 |
| **`innodb_buffer_pool_size`**| 物理内存 50%~60% | `256M` ~ `512M` | 测试模式轻量分配，防与其他微服务争抢内存 |
| **`max_connections`** | `2000` | `150` | 精简连接池数量，降低底层连接结构体开销 |
| **`binlog_cache_size`** | `32M` | `1M` | 规避每个事务连接预分配大内存触发 OOM |
| **`sort / join_buffer_size`**| `2M` | `512K` | 调优会话排序及关联缓冲区 |
| **`tmp_table_size`** | `256M` | `32M` | 内存内部临时表尺寸限制 |
| **`character-set-server`** | `utf8mb4` | `utf8mb4` | 完整的 UTF-8 字符集支持（含 Emoji） |
| **`lower_case_table_names`**| `1` | `1` | 表名不区分大小写（已做 `--initialize` 兼容） |
| **`innodb_strict_mode`** | `0` | `0` | 解决大字段报错 `Row size too large (> 8126)` |

---

## 📝 许可协议

本项目基于 [MIT License](LICENSE) 开源。
