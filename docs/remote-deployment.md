# 在 WSL 编译并部署到远程 Linux 主机

仓库提供 [`script/deploy-remote.sh`](../script/deploy-remote.sh)，自动完成远端检查、内核头文件同步、WSL 本地编译、安装文件暂存、SSH 上传和远端安装。

## 1. 当前主机与默认参数

本流程针对当前环境：

| 项目 | WSL 编译环境 | 远程运行环境 |
| --- | --- | --- |
| 系统 | Ubuntu 22.04 | Ubuntu 22.04 |
| 架构 | x86_64 | x86_64 |
| 地址 | 当前开发机 | `192.168.1.124` |
| SSH 用户 | — | `think` |
| 远端内核 | 不使用 WSL 内核头文件 | 检查时为 `6.8.1-1061-realtime` |
| EtherCAT 网卡 | — | Intel I225-V，`enp114s0` |
| EtherCAT 驱动 | 构建 `igc` 和 `generic` | 当前配置使用 `igc` |
| 安装前缀 | 暂存到本地缓存 | `/usr/local` |

脚本每次通过 SSH 获取实际运行内核，不会把上表的内核版本写死。它只支持同架构、GCC 构建内核、glibc 和 systemd 的 Linux 主机，不提供跨架构交叉编译。建议两端使用相同 Ubuntu 版本；脚本会拒绝本地 glibc 比远端新的环境，并在远端安装前检查生成程序的动态库依赖。

EtherCAT 包含内核模块，必须使用目标内核对应的配置、生成头文件和 `Module.symvers`。只指定版本号，或直接使用 WSL 的 `/lib/modules/$(uname -r)/build`，都不能替代目标内核的构建文件。参见 [Linux 外部模块构建说明](https://docs.kernel.org/kbuild/modules.html)。

## 2. 首次准备

### WSL 依赖

在 WSL 安装工具。当前远端内核由 GCC 12 构建，因此需要 GCC/G++ 12：

```bash
sudo apt update
sudo apt install build-essential gcc-12 g++-12 \
  autoconf automake libtool pkg-config \
  libelf-dev libssl-dev rsync openssh-client kmod util-linux
```

脚本从远端 `/proc/version` 识别内核使用的 GCC 主版本，默认使用对应的 `gcc-N`、`g++-N`。未来内核更换编译器版本时，需要先在 WSL 安装对应工具链。

### 远端依赖与登录

先确认能从 WSL 登录：

```bash
ssh think@192.168.1.124
```

在远端检查、必要时安装：

```bash
sudo apt update
sudo apt install rsync kmod libc-bin tar util-linux \
  linux-headers-$(uname -r)
```

远端需要运行 systemd，SSH 用户需要有 sudo 权限。编译发生在 WSL，远端不需要安装完整的项目编译工具链。实时内核的头文件软件包需要由对应的 Ubuntu 软件源提供；若找不到包，应先解决软件源或内核开发包问题。

SSH 和 sudo 会分别在终端请求密码，脚本不保存密码，也不把密码写入命令行。首次连接时按 SSH 提示核对主机密钥。可选使用密钥登录，减少重复输入：

```bash
# 没有合适密钥时再创建；不要覆盖已有密钥
ssh-keygen -t ed25519 -f ~/.ssh/ethercat_deploy
ssh-copy-id -i ~/.ssh/ethercat_deploy.pub think@192.168.1.124
```

### EtherCAT 配置

已有 `/etc/ethercat.conf` 时脚本会保留它。目前这台主机的主要配置为：

```bash
MASTER0_DEVICE="enp114s0"
DEVICE_MODULES="igc"
```

首次安装时，应先配置文件和网口；脚本在配置缺失时会停止，并打印远端已上传的 `ethercat.conf.example` 位置。将样例复制到 `/etc/ethercat.conf` 后编辑，再重新运行脚本。

使用 `--driver generic` 时，需自行将配置改成 `DEVICE_MODULES="generic"`，并按需要设置 `UPDOWN_INTERFACES="enp114s0"`。构建参数不会自动改写运行配置。脚本禁用旧式 init.d 文件安装，已有 `/etc/sysconfig/ethercat`、systemd override、udev 规则也不由脚本改写。

原生 `igc` 驱动启动时会替换常规网卡驱动。启动前确认目标网口用于 EtherCAT，并确保 SSH 走其他管理接口。此前检查中 `192.168.1.124` 使用无线接口；实际路由以运行时状态为准：

```bash
# 在远端执行，填写 WSL/Windows 的实际来源地址
ip route get <管理连接来源IP>
```

## 3. 使用方法

在 WSL 的仓库目录运行，勿对整个部署脚本使用 sudo：

```bash
cd /home/think/ethercat

# 只检查依赖、远端内核、架构、glibc 和 GCC 版本
./script/deploy-remote.sh --check

# 编译并安装；要求远端服务已停止且 EtherCAT 模块未加载
./script/deploy-remote.sh

# 在允许中断 EtherCAT 的维护窗口安装并启动服务
./script/deploy-remote.sh --restart
```

默认部署不会启动服务。若服务正在运行或 `ec_master` 仍在加载，默认安装会拒绝继续；可先停止使用主站的应用和服务，或明确使用 `--restart`。`--restart` 会停止服务、安装、启动服务并运行 `ethercat master`；如果应用占用导致模块无法卸载，会停止部署。它不会修改开机启动设置。

服务启动会操作真实 EtherCAT 网口；请在设备允许的维护窗口使用 `--restart`。

只生成安装文件：

```bash
./script/deploy-remote.sh --build-only
```

此模式仍需通过 SSH 读取目标信息、同步头文件，但不上传安装文件、不执行远端 sudo，也不停止或启动服务。它会检查本地模块版本，动态库依赖检查在实际远端安装前执行。

指定其他主机或密钥：

```bash
./script/deploy-remote.sh \
  --host 192.168.1.124 \
  --user think \
  --port 22 \
  --identity ~/.ssh/ethercat_deploy \
  --jobs 8 \
  --restart
```

其他选项：

| 参数 | 含义 |
| --- | --- |
| `--driver igc` | 默认：构建 `igc` 和 `generic` |
| `--driver generic` | 仅构建通用网卡驱动与主站 |
| `--work-dir /绝对路径` | 缓存和构建输出目录，必须在源码仓库外且不包含空白字符 |
| `--cc gcc-12 --cxx g++-12` | 显式指定编译器；CC 主版本仍须与目标内核一致 |
| `--ssh-option KEY=VALUE` | 追加 SSH 选项，可重复使用，如 `ProxyJump=user@jump-host` |
| `--help` | 查看全部参数 |

`--check`、`--build-only` 互斥；`--restart` 仅用于实际部署。脚本仅接受主机名或 IPv4 地址，不支持 IPv6 地址参数。编译器参数接受一个命令名或可执行文件路径，不接受包含额外参数的命令串。

## 4. 脚本执行过程与文件位置

1. 通过 SSH 读取运行内核、架构、glibc、头文件路径及内核编译器主版本。
2. 用 `rsync -L` 同步内核构建目录，复制符号链接指向的实际头文件和构建工具。
3. 从 Git 工作区复制源码快照，在快照中执行 `bootstrap` 和 `configure`。包含已跟踪文件的未提交修改，以及未被忽略的新文件；排除已删除文件、忽略文件、Git 元数据和仅用于文档的 `doxygen-layout` 子模块。
4. 在 WSL 编译用户态工具、库和内核模块，使用 `DESTDIR` 和 `INSTALL_MOD_PATH` 暂存安装文件，检查模块 `vermagic`。
5. 将安装文件上传到远端独立的 `/tmp/ethercat-deploy.*` 目录，排除完整源码构建目录。
6. 在远端用 sudo 再次检查运行内核、动态库依赖、模块版本和服务状态。备份已有文件，记录新增文件，安装后执行 `depmod`、`ldconfig` 和 `systemctl daemon-reload`。
7. 只有 `--restart` 才会启动服务。成功后删除远端临时上传目录；失败时保留它以供排查。

源码仓库不会生成编译产物，也不会自动提交代码。每次创建新的源码快照并完整构建，避免将旧配置或旧对象文件带入新部署。头文件缓存可重用。默认输出根目录：

```text
~/.cache/ethercat-deploy/think@192.168.1.124-22/<远端内核>/
├── kernel/                         # 目标内核构建文件缓存
└── releases/<时间>-<进程号>/
    ├── build/                      # 源码快照与编译产物
    ├── root/                       # 暂存安装文件
    ├── ethercat.conf.example       # 配置样例，不覆盖远端配置
    ├── build-info.txt              # 目标、内核、Git 版本和编译器
    └── install-remote.sh           # 实际部署时生成的远端安装程序
```

若设置了 `XDG_CACHE_HOME`，默认缓存位于该目录下。可以在不运行部署时删除旧 release 目录释放空间；头文件缓存删除后会在下次重新同步。

远端安装内容包括 `/usr/local` 下的工具、库、头文件及辅助文件，`/lib/modules/<内核>/ethercat/` 下的模块，以及 `/lib/systemd/system/ethercat.service`。不使用 `rsync --delete`，不删除其他安装内容。同步保留 `/lib -> usr/lib` 这类已有目录链接，不把 WSL 内核构建路径链接安装到远端。

## 5. 验证与回滚

在远端检查安装结果：

```bash
modinfo -n ec_master
modinfo -F vermagic ec_master
modinfo -n ec_igc
sudo systemctl status ethercat --no-pager
```

模块版本开头应与远端 `uname -r` 一致。默认部署后服务应保持停止，确认设备状态后手动启动：

```bash
sudo systemctl start ethercat
sudo /usr/local/bin/ethercat master
sudo /usr/local/bin/ethercat slaves
```

每次进入安装阶段，脚本都会在远端打印独立的备份目录，例如 `/var/backups/ethercat-deploy.ABCDEFGH`。目录包含部署前已有文件的归档、新增文件清单、配置备份和 `rollback.sh`。需要回滚时，先停止使用 EtherCAT 的应用，再执行实际打印路径下的脚本：

```bash
sudo bash /var/backups/ethercat-deploy.ABCDEFGH/rollback.sh
```

回滚会停止服务、确认模块已卸载、删除本次新增文件、恢复被覆盖文件，并刷新模块和库缓存。它保留当前 `/etc/ethercat.conf`，也不会自动启动服务；旧配置副本位于备份目录的 `ethercat.conf`，需要时自行比较恢复。新增的空目录可能保留。连续多次部署的备份应从最近一次开始逆序回滚。

安装和回滚都是逐文件操作，并非事务；断电或中途失败需要根据备份恢复。安装失败后不要直接假定服务仍在运行。

## 6. 常见问题

- **缺少 `gcc-N` / `g++-N`**：在 WSL 安装脚本提示的主版本。当前目标内核使用 GCC 12，而系统默认的 `gcc` 可能仍是 11，不必修改系统默认编译器。
- **头文件不存在或缺少 `Module.symvers`**：在远端准备与运行内核完全对应的开发包。脚本不会自动安装依赖或更新内核。
- **内核更新后部署失败**：重启到计划使用的内核后重新执行脚本。若编译期间远端内核变化，安装检查会拒绝继续。
- **`kernel ... not available for igc driver`**：仓库没有该内核系列的原生驱动。先确认兼容性，或使用 `--driver generic` 并自行调整 `/etc/ethercat.conf`。
- **动态库版本缺失**：使用与远端匹配的 Ubuntu/工具链构建环境，或先解决远端所需运行库版本；不要直接绕过检查。
- **Secure Boot 拒绝加载模块**：检查 `sudo dmesg` 中的签名错误，并按目标系统已有的模块签名/MOK 流程处理。脚本不关闭 Secure Boot，也不自动管理签名密钥；`vermagic` 一致不代表签名一定被内核接受。
- **服务停止后模块仍在使用**：先退出占用 EtherCAT 设备或主站模块的实时应用，再部署。
- **模块解析到了其他位置**：脚本会检查 `modinfo -n` 是否指向本次安装的文件。若有旧版或 DKMS 安装优先于 `/lib/modules/<内核>/ethercat/`，应先整理重复安装，再执行 `depmod` 和部署。
- **SSH/sudo 失败**：从交互终端运行，确认主机密钥、SSH 凭据和远端 sudo 权限。无人值守运行需自行准备密钥及适用的 sudo 配置。

查看启动失败详情：

```bash
sudo journalctl -u ethercat -n 80 --no-pager
sudo dmesg | tail -80
```
