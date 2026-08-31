# IgH EtherCAT Master 编译、配置与实例运行指南

本文档详细介绍 IgH EtherCAT Master(版本 1.6.12)如何编译、如何配置,以及如何快速运行示例程序。

## 1. 总览

IgH EtherCAT Master 是一个运行在 Linux 之上的 EtherCAT 主站实现。它由以下几部分组成:

- **内核模块 `ec_master.ko`**:主站核心,负责总线扫描、从站配置、过程数据交换。运行在 `master/` 目录下。
- **网络设备驱动模块**:将 EtherCAT 帧收发的网络设备接入主站,位于 `devices/` 目录下。
- **用户空间库 `libethercat`**:向实时应用提供 `ecrt_*` 应用接口(内核态调用的是同一套 API)。位于 `lib/`。
- **命令行工具 `ethercat`**:调试和监控工具,位于 `tool/`。

构建采用 **Autotools(configure/make)+ 内核模块 out-of-tree 构建(Kbuild)**。编译内核模块需要一套已配置好的 Linux 内核源码树。

## 2. 构建前提

### 2.1 软件需求

- 一套**已配置**的 Linux 内核源码树。可以是用 `make defconfig` 配置过的源码目录,也可以是打包内核头文件后的 `/lib/modules/$(uname -r)/build` 目录。
- Autotools 工具链:autoconf、automake、libtool、m4、gcc、make。
- 编译驱动模块还可能需要对应内核开发包(如 `linux-headers-*`)。

如果 `configure` 找不到内核源码,会直接报错:

```
Failed to find Linux sources. Use --with-linux-dir!
```

此时必须用 `--with-linux-dir` 显式指定内核源码路径。

### 2.2 从 Git 仓库获取源码

`configure` 脚本并不随仓库提交,需要先运行 `bootstrap` 生成:

```bash
git clone <repository-url> ethercat
cd ethercat
./bootstrap     # 内部执行 autoreconf -i,生成 ./configure
```

仓库包含一个子模块 `doxygen-layout`(用于生成 doxygen 文档)。如果不需要生成 doxygen 文档,可以跳过:

```bash
# 需要文档时才执行
git submodule update --init
```

## 3. 配置(configure)

`configure` 决定编译哪些组件、启用哪些网络设备驱动、目标内核版本等。

### 3.1 一条典型的完整配置命令

```bash
./configure \
    --sysconfdir=/etc \
    --with-linux-dir=/usr/src/linux-6.18.45-rt \
    --enable-8139too --enable-e100 --enable-e1000 --enable-e1000e \
    --enable-igb --enable-igc --enable-macb --enable-ccat
```

### 3.2 常用配置项

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| `--with-linux-dir=<DIR>` | 当前运行内核的 `/lib/modules/$(uname -r)/build` | Linux 内核源码路径 |
| `--enable-kernel` / `--disable-kernel` | 启用 | 是否构建内核模块 |
| `--enable-userlib` / `--disable-userlib` | 启用 | 是否构建用户空间库 `libethercat` |
| `--enable-tool` / `--disable-tool` | 启用 | 是否构建命令行工具 `ethercat` |
| `--enable-fakeuserlib` | 禁用 | 构建 `libfakeethercat` 假库(需要 RtIPC 库 `librtipc`) |
| `--enable-tty` | 禁用 | 构建 `ec_tty` TTY 接口模块 |
| `--enable-eoe` / `--disable-eoe` | 受限 | 是否启用 Ethernet over EtherCAT(EoE) |
| `--enable-rtdm` | 禁用 | 是否启用 RTDM 接口(Xenomai/RTAI 用户空间实时访问) |
| `--enable-8139too` | 禁用 | 编译 8139too 驱动 |
| `--enable-e100` | 禁用 | 编译 e100 驱动 |
| `--enable-e1000` | 禁用 | 编译 e1000 驱动 |
| `--enable-e1000e` | 禁用 | 编译 e1000e 驱动 |
| `--enable-igb` | 禁用 | 编译 igb 驱动 |
| `--enable-igc` | 禁用 | 编译 igc 驱动 |
| `--enable-genet` | 禁用 | 编译 bcmgenet 驱动 |
| `--enable-macb` | 禁用 | 编译 macb 驱动 |
| `--enable-r8169` | 禁用 | 编译 r8169 驱动(含 `--enable-stmmac-pci`、`--enable-dwmac-intel`) |
| `--enable-ccat` | 禁用 | 编译 ccat 驱动(以内存映射方式访问 ESC) |
| `--with-devices=<N>` | 1 | 支持的主站/设备数量,决定 `EC_MAX_MASTERS`、`EC_MAX_NUM_DEVICES` |

> **重要**:驱动默认都不启用。必须用 `--enable-<driver>` 显式开启你需要的驱动。其中 `--with-devices` 会改变 `EC_MAX_MASTERS`/`EC_MAX_NUM_DEVICES` 等编译时常量,需要在编译内核模块**之前**确定,因为它们在 `master/globals.h` 中定义。

### 3.3 常见组合场景

- **只构建用户空间库**(无内核模块,用于开发/测试用户态应用):
  ```bash
  ./configure --disable-kernel
  make
  ```

- **不带任何驱动,只编译主站模块**:
  ```bash
  ./configure --with-linux-dir=/usr/src/linux-xxx --disable-8139too
  ```

- **用假库做干跑(dry-run)仿真**(参考 `fake_lib/README.md`):
  ```bash
  ./configure --enable-fakeuserlib --disable-kernel
  make
  ```

### 3.4 配置生成

`configure` 会生成顶层的 `Makefile`、各目录的 `Makefile`、以及各个 `Kbuild`(从 `Kbuild.in` 生成)。这些生成文件都被 `.gitignore` 忽略,不应提交。

## 4. 编译与安装

### 4.1 编译

```bash
make all modules
```

- `make all` 构建用户空间组件(`libethercat`、`ethercat` 工具、`examples`)。
- `make modules` 通过 Kbuild 构建内核模块(`ec_master.ko` + 各设备驱动 + 可选的 `ec_tty.ko`)。

`make all modules` 是 `make all` 与 `make modules` 的组合,一步完成。

### 4.2 只编译内核模块

```bash
make modules
```

### 4.3 只编译某个驱动

Kbuild 的 `make` 会进入各子目录,可用 `-C` 指定:

```bash
make -C devices/igb modules
```

### 4.4 安装(需 root)

```bash
sudo make modules_install install
sudo depmod
```

- `make modules_install` 安装内核模块到 `/lib/modules/<kernelrelease>/`。
- `make install` 安装用户空间库、工具、头文件(`include/ecrt.h`)、systemd/init 脚本。

### 4.5 清理

```bash
make clean        # 先执行 Kbuild clean,再执行 automake clean
make mrproper     # 移除所有生成文件、configure、config.h 等
```

### 4.6 安装后配置

编辑配置文件:

```bash
# systemd 发行版
sudo vi /etc/ethercat.conf
# init.d 发行版
sudo vi /etc/sysconfig/ethercat
```

典型内容:

```
MASTER0_DEVICE="eth0"     # 或指定的 MAC 地址
DEVICE_MODULES="generic"  # 使用的驱动模块,generic/8139too/igb/...
```

`udev` 会自动创建 EtherCAT 字符设备。若希望普通用户可读,添加 udev 规则:

```bash
echo 'KERNEL=="EtherCAT[0-9]*", MODE="0664"' | sudo tee /etc/udev/rules.d/99-EtherCAT.rules
```

启动主站:

```bash
# systemd 发行版
sudo systemctl start ethercat
# init.d 发行版
sudo /etc/init.d/ethercat start
```

## 5. 快速运行示例程序

示例位于 `examples/` 目录。最常用的是面向用户空间实时应用的 `examples/user/`。

### 5.1 用户空间示例(推荐)

目标:`examples/user/ec_user_example`。它创建一个域、配置几个典型 Beckhoff 从站(EL3102 / EL4102 / EL2032 / EK1100)的 PDO、激活主站并以 1 ms 周期循环收发过程数据。

前提:
1. 已按上文编译并安装主站与 `libethercat`。
2. 已加载 `ec_master` 内核模块(由 systemd 服务或 `modprobe ec_master` 完成)。
3. 你的 EtherCAT 总线上的从站与示例中硬编码的从站**对应**(否则示例会因从站类型不匹配而失败)。

```bash
cd examples/user
make        # 生成 ec_user_example
sudo ./ec_user_example
```

如果 `make` 报找不到 `-lethercat`,先用 `make` 在顶层完成 `lib/` 的构建。

程序启动后按 1 ms 周期运行,可通过 `dmesg` 或程序自身的 `printf`(当主站状态、域状态、从站配置状态变化时)观察输出。可用 `Ctrl+C` 终止。

> 提示:若要基于自己的从站改造示例,需要修改 [examples/user/main.c](examples/user/main.c) 中的:
> - 设备常量(`Beckhoff_EL2xxx` 的 vendor_id/product_code);
> - 从站位置宏(`DigOutSlavePos` 等);
> - PDO 配置表(`el3102_pdos`、`el4102_pdos`、`el2004_channels` 等)。

### 5.2 内核模块示例(最小示例)

目标:`examples/mini/ec_mini.ko`。它用内核定时器生成周期任务,是从内核模块调用实时接口的最简模板。

```bash
cd examples/mini
make modules        # 生成 ec_mini.ko
sudo insmod ec_mini.ko
# 查看日志输出
dmesg | tail
```

> 提示:示例中已按你的总线调整过程数据部分(见 `examples/mini/README`)。内核态应用使用同一套 `ecrt_*` API,只是处于内核上下文而非用户空间。

### 5.3 使用命令行工具验证

安装后,`ethercat` 工具可用来检查和操作总线:

```bash
# 列出所有从站
sudo ethercat slaves

# 查看主站状态(连接状态、从站数量等)
sudo ethercat master

# 显示某从站的 PDO 信息
sudo ethercat pdos

# 读取某从站 SDO
sudo ethercat sdo read <slave> <index> <subindex>

# 从站状态切换
sudo ethercat states
sudo ethercat states --init 0
```

## 6. 验证与测试

项目中并没有独立的单元测试框架,CI 主要做以下检查:

- **`make distcheck`** —— Autotools 的标准 distcheck,验证发布包可重新配置、编译、安装。
- **`make -C lib symbol-version-check`** —— 校验所有标记为 `EC_PUBLIC_API` 的符号都已列入 `lib/libethercat.map` 的版本控制表。若导出符号未版本化,此命令返回非零。

```bash
# 检查公共 API 符号版本化是否完善
make -C lib symbol-version-check
```

## 7. 故障排查

| 现象 | 可能原因 / 解决 |
|------|----------------|
| `Failed to find Linux sources` | 未指定 `--with-linux-dir`,而当前运行内核缺少头文件。显式指定内核源码路径。 |
| 编译驱动时改错内核头文件 | 驱动按内核版本 vendored(见 `devices/` 下的 `*-<version>-ethercat.c`),需确保 `--with-linux-dir` 指向的正确内核源码。 |
| `modprobe: module ec_master not found` | 未运行 `make modules_install` 或未 `depmod`。 |
| 示例从站不响应 / 配置失败 | 示例中硬编码的从站类型(vendor_id/product_code)与实际总线不符,需修改 `main.c` 中的常量。 |
| 无 EthernetCAT 字符设备 | 确认 `ec_master` 模块已加载、udev 规则存在。 |

## 8. 参考

- 在线手册:https://docs.etherlab.org/ethercat/1.6/doxygen/index.html
- 硬件支持表:`make doc` 生成的 `device_drivers.md`,以及 [devices/create_driver_table.py](devices/create_driver_table.py)。
- 编译与安装的官方说明见 [INSTALL.md](../INSTALL.md)。
- API 函数调用流程见 [api-guide.md](api-guide.md)。
