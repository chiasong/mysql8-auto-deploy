# mysql8-auto-deploy (MySQL 8.0.46 生产级自动化部署项目)

[![MySQL](https://img.shields.io/badge/MySQL-8.0.46-blue.svg)](https://www.mysql.com/)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Linux-lightgrey.svg)](https://www.kernel.org/)

一套专为 Linux 生产环境打造的 **MySQL 8.0.46 一键自动化部署脚本**。支持智能识别系统 `glibc` 版本与 CPU 架构，自动匹配拉取官方二进制包，并具备硬件资源智能计算、端口占用校验、12 位高强度随机密码生成及外部远程访问开箱即用能力。

---

## 🌟 核心特性

- 🧠 **glibc 与架构智能匹配**：自动检测系统 `glibc` 版本（区分 `glibc2.17` / `glibc2.28`）及 CPU 架构（`x86_64` / `aarch64`），拉取官方匹配包。
- ⚡ **一键极速部署**：从依赖安装、用户创建、二进制解压、配置文件生成到 Systemd 服务注册全自动化完成。
- ⚙️ **交互式路径与端口配置**：支持自定义部署主目录与服务端口，内置端口占用实时检测与二次提醒。
- 💾 **InnoDB 内存智能适配**：依据系统总物理内存，动态计算分配最优的 `innodb_buffer_pool_size` 与 `instances`。
- 🔒 **高安全性**：命令行自动生成 12 位随机高强度密码，自动配置 `root@%` 远程访问权限。
- 🛠️ **生产级 my.cnf 优化**：统一 `utf8mb4` 字符集，修正 MySQL 8.0 `lower_case_table_names=1` 初始化陷阱，优化会话缓存防 OOM。

---

## 🚀 快速开始

### 极速一键安装

在 Linux 服务器终端执行以下命令：

```bash
# 从仓库一键下载并启动安装
wget -O install_mysql8.sh https://gitee.com/<您的Gitee用户名>/mysql8-auto-deploy/raw/main/install_mysql8.sh && chmod +x install_mysql8.sh && sudo ./install_mysql8.sh
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
2. **选择服务端口**（默认 `3306`）：自动校验 1-65535 端口有效性及是否被占用。
3. **自动化部署**：自动下载官方包、配置 `/etc/my.cnf`、初始化数据库、启动服务并生成 12 位 root 随机密码。

---

## 📄 my.cnf 关键配置参数

| 配置项 | 预设值 | 说明 |
| :--- | :--- | :--- |
| `character-set-server` | `utf8mb4` | 完整的 UTF-8 字符集支持（含 Emoji） |
| `lower_case_table_names` | `1` | 表名不区分大小写（已做 `--initialize` 兼容） |
| `innodb_buffer_pool_size` | 动态分配 | 自动按系统物理内存 50%~60% 计算分配 |
| `innodb_redo_log_capacity`| `2G` | MySQL 8.0.30+ 官方推荐的动态 Redo Log 配置 |
| `sort_buffer_size` | `2M` | 安全的会话级排序缓存，防止高并发下 OOM |

---

## 📝 许可协议

本项目基于 [MIT License](LICENSE) 开源。
