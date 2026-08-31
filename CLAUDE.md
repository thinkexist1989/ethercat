# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

This is the **IgH EtherCAT Master** — an open-source EtherCAT master implementation for Linux 2.6+ (current version: 1.6.12). EtherCAT is a real-time industrial Ethernet fieldbus; this codebase implements the master side: it scans a bus of EtherCAT slaves, configures their PDO/SDO mappings, and exchanges process data under real-time constraints.

The master is built as a **Linux kernel module** plus an optional userspace companion library. A real-time application can call it either from kernel context or from userspace via the `libethercat` library (which talks to the kernel module through a character device / ioctl interface).

Online manual: https://docs.etherlab.org/ethercat/1.6/doxygen/index.html

## Build system

Autotools + out-of-tree kernel module builds. Every kernel-module subdirectory uses `Kbuild.in`/`Makefile.am` which `include $(top_srcdir)/Makefile.kbuild` — that file defines the `$(KBUILD)` macro that delegates to `make -C $(LINUX_SOURCE_DIR) M=...`.

Building requires a configured Linux kernel source tree.

```bash
# From a fresh repo checkout:
./bootstrap                 # runs autoreconf -i, generates ./configure

./configure --sysconfdir=/etc   # defaults: kernel on, generic driver on
make all modules                # builds userspace + kernel modules

# As root:
make modules_install install
depmod
```

### Common configure options

`--with-linux-dir=<DIR>` points to kernel sources (defaults to running kernel via `/lib/modules/$(uname -r)/build`). Device drivers are each enabled individually:

```bash
./configure --enable-8139too --enable-igb --enable-e100 --enable-macb --enable-ccat \
    --with-linux-dir=/usr/src/linux-6.18.45-rt
```

Major toggles (all `--enable-X` / `--disable-X`): `kernel`, `generic`, `8139too`, `e100`, `e1000`, `e1000e`, `genet`, `macb`, `igb`, `igc`, `r8169`, `stmmac-pci`, `dwmac-intel`, `ccat`, `rtdm`, `eoe`, `debug-if`, `tool` (the `ethercat` CLI), `userlib` (libethercat), `fakeuserlib` (libfakeethercat), `tty`, `xenomai`, `xenomai-v3`, `rtai`.

Note: `--with-devices=<N>` sets the number of supported masters/devices and is baked into `EC_MAX_MASTERS`/`EC_MAX_NUM_DEVICES`. Change it before building the kernel module — it affects `master/globals.h`.

### Single-purpose builds

- **Userspace library only**: `./configure --disable-kernel && make`
- **Build the `ethercat` CLI tool** only: `--enable-tool` (default when userspace enabled)
- **Documentation PDF**: `cd documentation && make` (the LaTeX handbook)
- **Doxygen**: `make doc` (generates `device_drivers.md` then runs doxygen; needs `git submodule update --init` for doxygen-layout)
- **Run tests**: there is no unit-test framework. The CI uses `make distcheck` and `make -C lib symbol-version-check` (verifies all `EC_PUBLIC_API` symbols are versioned in `libethercat.map`).

## Architecture

### The three-layer split

The codebase is divided by *where code runs*:

1. **`master/`** — the kernel module `ec_master.ko`. The core: datagrams, the bus FSM, slave scanning, PDO/SDO/SoE/VoE, DC (distributed clock) sync, and the character-device ioctl driver (`cdev.c`, `ioctl.c`, `ioctl.h`). `module.c` is the module init/exit entry point. This is where the bulk of protocol logic lives.

2. **`lib/`** — the userspace `libethercat` library, a *thin wrapper* over the kernel ioctl interface. Each `.c` file here (`master.c`, `domain.c`, `sdo_request.c`, etc.) mirrors a kernel-side subsystem and just packs/unpacks ioctl requests. The public API header is `include/ecrt.h` (`ecrt_*` functions). There is also `libethercat_rtdm` built for Xenomai/RTAI userspace RTDM access.

3. **`devices/`** — EtherCAT-capable network device drivers. These implement the **device interface** in `devices/ecdev.h` (`ecdev_offer`, `ecdev_receive`, `ecdev_set_link`, etc.) to hand frames to the master. Most are EtherCAT-forked copies of standard Linux drivers.

### The device interface (`ecdev.h`)

EtherCAT-capable network drivers call `ecdev_offer(net_dev, poll, module)` at probe time to attach to the master, then use `ecdev_receive`/`ecdev_set_link` to feed received frames and link-state to the master. The master sends frames back through the device. This is the key decoupling: the master module knows nothing about specific NIC hardware — only the `ec_device_t` abstraction. The generic driver (`devices/generic.c`) allows any Linux-supported NIC to work by hooking the network stack instead.

### How drivers are maintained per kernel version

Native drivers in `devices/` are vendored per-kernel-version. Each file is either `<name>-<ver>-ethercat.c` (the EtherCAT-modified version) or `<name>-<ver>-orig.c` (the pristine upstream copy). Directories like `devices/igb/` hold whole variants of the upstream Intel driver, one set per kernel line. **When porting a driver to a new kernel version**, the flow is to run `devices/update.sh <kerneldir> <prev> <new>` (diff the prev-ethercat vs prev-orig patch onto the new kernel's driver), or regenerate from upstream and re-apply the EtherCAT diff manually. `make doc` / `make generated_table.md` runs `devices/create_driver_table.py` to document which drivers exist.

### The master FSM and phases

`master/fsm_*.c` implement the master finite state machine. The `ec_master` struct (`master/master.h`) has a `phase` field of type `ec_master_phase_t`:
- `EC_ORPHANED` — no Ethernet device attached
- `EC_IDLE` — device attached, master not activated; the master thread drives the bus
- `EC_OPERATION` — an application called `ecrt_master_activate()`; the *application* now drives send/receive

Before activation the master runs the bus itself (scanning, config, idle datagrams). After activation, the application `ecrt_master_send()`/`ecrt_master_receive()` and all configuration is frozen. The api_usage notes in [master/api_usage_notes.md](master/api_usage_notes.md) document which functions are `rt_safe` vs `blocking` and which require `master_idle`/`master_op`/`master_any` — **read this before writing master/ or lib/ code**.

### The application interface (`ecrt.h`)

`include/ecrt.h` is the sole public API. Feature availability is gated by `EC_HAVE_*` macros (e.g. `EC_HAVE_SOE_REQUESTS`, `EC_HAVE_REG_ACCESS`) — these are how an application compiles against different versions. The ioctl interface number `EC_IOCTL_VERSION_MAGIC` (in `master/ioctl.h`) is **incremented whenever the ioctl ABI changes**; keep it in sync with `lib/` and `tool/`.

### The `ethercat` CLI tool (`tool/`)

A C++ binary connecting to the master's char device, one `Command*.cpp` per subcommand (`states`, `config`, `pdos`, `sdo`, `foe`, `reg`, `graph`, `download`, `slaves`, ...). `MasterDevice.cpp` handles the ioctl transport. `CommandCStruct.cpp`/`CommandXml.cpp` generate C structs/XML from SII data. This is the reference consumer of the ioctl interface.

### Other components

- **`fake_lib/`** — `libfakeethercat`, a userspace library with the *same API* as `libethercat` but no real master, used for dry-run/field simulation. Selected with `--enable-fakeuserlib`, swapped in via `LD_LIBRARY_PATH`. See [fake_lib/README.md](fake_lib/README.md).
- **`tty/`** — optional `ec_tty` module exposing master/slave info through a TTY interface (`--enable-tty`).
- **`examples/`** — sample realtime applications (`examples/user/` for userspace, `examples/mini/` and others for kernel modules).
- **`script/`** — `/etc/ethercat.conf` / systemd unit / init.d scripts (`ethercatctl`, `ifup-eoe.sh`).

## Coding conventions

- C files use the project style in [CodingStyle.md](CodingStyle.md): **max 78-col lines**, 4-space indent, K&R braces (opening brace on its own line for *functions*, same line for control blocks), CAPS macros with `do{}while(0)`.
- **Exception**: EtherCAT device drivers in `devices/` follow the Linux kernel coding style, not the project style — they're forks of upstream kernel code.
- `cpplint` runs via pre-commit hooks ([.pre-commit-config.yaml](.pre-commit-config.yaml)); `CPPLINT.cfg` files (repo root and per-driver dirs) carry the allowed filters and `linelength=78`. Install hooks with `pre-commit install`.
- Userspace lib symbols are marked `EC_PUBLIC_API` and must be listed in `lib/libethercat.map`; `make -C lib symbol-version-check` enforces this.
- Revision string is embedded into kernel objects via `-DREV=$(git describe)` in the `Kbuild.in` files.

## Notes

- The controller clock: `EC_MAX_MASTERS` (default 1) and `EC_MAX_NUM_DEVICES` control master/device counts and come from `--with-devices`; set at configure time.
- `globals.h` at repo root is shared across the kernel module and included by driver code — it holds version strings and common `EC_MAX_*`/`EC_RATE_COUNT` limits.
- New device drivers should be added to `devices/`, wired into `devices/Makefile.am`, `devices/Kbuild.in`, `devices/create_driver_table.py`, and `configure.ac` (which registers the `--enable-<driver>` / `--with-<driver>-kernel` options).
