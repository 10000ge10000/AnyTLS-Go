# 精简项目结构

## 📁 项目文件（仅4个核心文件）

```
AnyTLS-Go/
├── .gitignore          # Git忽略文件配置
├── README.md           # 项目主说明文档（4KB）
├── INSTALL_GUIDE.md    # 详细安装指南（16KB）
└── install.sh          # 一键安装脚本（36KB）
```

## ✅ 精简说明

### 删除的内容
- ❌ 所有Go源码文件和目录（`cmd/`, `proxy/`, `util/`）
- ❌ Go语言项目配置（`go.mod`, `go.sum`, `.goreleaser.yaml`）
- ❌ 原项目文档目录（`docs/`）
- ❌ 冗余文档文件（`INSTALLATION_README.md`, `PROJECT_SUMMARY.md`）
- ❌ 辅助脚本（`quick-deploy.sh`, `one-line-install.sh`, `test-install.sh`, `verify-install.sh`）

### 保留的核心文件
- ✅ `install.sh` - 核心一键安装脚本（36KB）
- ✅ `README.md` - 简洁的项目说明（4KB）
- ✅ `INSTALL_GUIDE.md` - 详细的安装指南（16KB）
- ✅ `.gitignore` - Git配置文件

## 🎯 精简效果

- **总文件数**: 从 36+ 个文件减少到 4 个核心文件
- **项目大小**: 大幅减小，只保留必要的安装文件
- **功能**: 保持完整的一键安装功能
- **文档**: 保留核心说明和详细指南

## 🚀 使用方式

```bash
# 一键安装
bash <(curl -fsSL https://raw.githubusercontent.com/10000ge10000/AnyTLS-Go/main/install.sh)
```

项目现在专注于提供简洁、高效的AnyTLS-Go一键安装解决方案！