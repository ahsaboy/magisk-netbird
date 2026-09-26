<p align="center">
  <img src="docs/netbird-logo.png" alt="NetBird logo" width="340">
</p>

<h1 align="center">Magisk NetBird</h1>

<p align="center">
  <img alt="Release" src="https://img.shields.io/github/v/release/ahsaboy/magisk-netbird?logo=git&logoColor=white">
  <img alt="CI" src="https://img.shields.io/github/actions/workflow/status/ahsaboy/magisk-netbird/release.yml?branch=main&label=CI&logo=githubactions&logoColor=white">
  <img alt="Downloads" src="https://img.shields.io/github/downloads/ahsaboy/magisk-netbird/total?logo=github&logoColor=white">
  <img alt="NetBird" src="https://img.shields.io/github/v/release/netbirdio/netbird?label=NetBird">
  <img alt="Magisk" src="https://img.shields.io/badge/Magisk-%E2%89%A520.4-green?logo=magisk&logoColor=white">
  <img alt="Arch" src="https://img.shields.io/badge/arch-arm64%20%7C%20armv7%20%7C%20x86__64-lightgrey?logo=android&logoColor=3C4043">
</p>

<p align="center"><b><a href="README.md">English</a> · <a href="README.zh-CN.md">中文</a></b></p>

NetBird CLI 常驻进程的精简 Magisk 模块封装。为三种架构打包官方 NetBird
二进制（当前 v0.79.0），由 GitHub Actions 自动构建。

使用 `netbird.service up` 加入网络时，默认禁用 DNS 管理。

## 下载

| 压缩包 | 适用设备 |
| --- | --- |
| `magisk-netbird-arm64-v8a.zip` | arm64-v8a（大多数现代手机） |
| `magisk-netbird-armv7.zip` | 32 位 ARM（armeabi-v7a） |
| `magisk-netbird-x86_64.zip` | x86_64（模拟器、部分 Chromebook） |

最新发布：<https://github.com/ahsaboy/magisk-netbird/releases/latest>

每次安装都会把对应架构的 `updateJson` 写入 `module.prop`
（`update/update-<arch>.json`），因此新版本发布后 Magisk App 会显示
**发现新版本**横幅。Kitsune 和旧版管理器同样支持该横幅；ACTION 按钮需要
Magisk v28+。

## 发布新版本

```sh
# 先在 module.prop 中提升 version + versionCode（v1.3.0 -> 10300）并提交，然后：
git tag v1.3.0
git push origin main v1.3.0
```

`Release` 工作流会为每个架构下载对应的官方 NetBird 发布包、用
`checksums.txt` 校验 sha256、打包三个 zip、附加到 GitHub Release，并在
`main` 分支上刷新 `update/*.json`、`update.json` 和 `CHANGELOG.md`。
写入的显示版本格式为 `<tag>-(<NetBird 版本>)`（如 `v1.3.0-(0.79.0)`），
更新检测本身以 `versionCode` 为准。

不走 CI 的本地打包（需要先放置 `netbird/bin/netbird-<arch>`，否则安装脚本
会在安装时回退为在线下载）：

```sh
zip -r9 magisk-netbird-local.zip META-INF customize.sh module.prop service.sh \
  uninstall.sh action.sh README.md netbird system
```

## 使用

重启前：

```sh
su -c '/dev/netbird.service up --setup-key <KEY> --management-url <URL>'
su -c '/dev/netbird.service status'
```

重启后：

```sh
su -c 'netbird.service up --setup-key <KEY> --management-url <URL>'
su -c 'netbird.service status'
su -c 'netbird.service log'
```

为避免 setup key 进入 shell 历史和 `ps` 输出，建议改用文件方式：

```sh
su -c 'echo -n <KEY> > /data/adb/netbird/setup.key && chmod 600 /data/adb/netbird/setup.key'
su -c 'netbird.service up --setup-key-file /data/adb/netbird/setup.key --management-url <URL>'
```

查看每个对端的连接细节（P2P 直连 / Relayed 中转、延迟、流量、最近握手）：

```sh
su -c 'netbird.service peers'
```

在 Magisk App（v28+）中，模块的 **ACTION** 按钮会执行 `action.sh`：刷新
CA 证书包、路由规则和防火墙规则，然后输出状态。

## 配置

默认值在 `netbird/settings.sh` 中设置；可通过环境变量覆盖（NetBird 中
环境变量的优先级高于命令行参数）：

| 变量 | 默认值 | 作用 |
| --- | --- | --- |
| `NB_DISABLE_DNS` | `true` | `up` 时同时通过 `--disable-dns` 强制禁用 DNS 管理。 |
| `NB_DISABLE_IPV6` | `false` | 为 `true` 时 `up` 追加 `--disable-ipv6`；该选项会关闭 NetBird overlay IPv6，不用于规避防火墙兼容性问题。 |
| `NB_DISABLE_FIREWALL` | `false` | 为 `true` 时 `up` 追加 `--disable-firewall`（客户端不再管理防火墙规则）。 |
| `NB_FORCE_USERSPACE_FIREWALL` | `自动` | Android 缺少可用的 `ip6tables` nat 表时自动启用；显式设置可覆盖自动检测。 |
| `NB_WG_KERNEL_DISABLED` | `自动` | userspace firewall 回退启用时自动强制 userspace WireGuard，除非用户显式设置。 |
| `NB_DISABLE_SSH_CONFIG` | `true` | 跳过写入 `/etc/ssh/ssh_config.d`（Android 上为只读）。 |
| `NB_SKIP_NFTABLES_CHECK` | `true` | 跳过 nftables 探测（该探测在 Android 上必然失败）。 |
| `NB_SKIP_DNS_PROBE` | `true` | 跳过本地解析器启动探测。 |
| `NB_NETWORK_MONITOR` | `true` | 上游在 Linux 上默认为 `false`；此处启用以便网络切换后更快重连。 |
| `NB_STATE_DIR` | `/data/adb/netbird` | `state.json` / WireGuard 密钥的可写存放目录（上游默认的 `/var/lib/netbird` 在 Android 上不存在）。 |
| `NB_LOG_LEVEL` | `info` | NetBird 日志级别。 |
| `NB_LOG_MAX_SIZE_MB` | `5` | NetBird 自带的 `client.log` 轮转上限（MiB，上游默认 15）。 |
| `NB_WATCHDOG` | `on` | 看门狗：daemon 状态连续无响应时自动重启；`off` 关闭。 |
| `NB_WATCHDOG_FAILS` | `3` | 连续多少次状态探测失败（每刷新周期一次）后触发重启。 |
| `NB_WATCHDOG_MAX_RESTARTS` | `10` | 重启预算；连续 5 个健康周期后重置。 |

上表所有变量（以及官方客户端支持的任何其他变量）都可以持久化到
`/data/adb/netbird/.env`（每行 `KEY=VALUE`，`#` 开头为注释）；真实环境
变量依然优先于该文件。从已安装的模板开始：

```sh
cp /data/adb/netbird/netbird.env.example /data/adb/netbird/.env
```
daemon 读取的变量（如 `NB_LOG_LEVEL`）在下次 `netbird.service restart`
后生效，无需重启手机。Android 缺少可用的 IPv6 `nat` 表时，模块会自动启用
NetBird userspace firewall 和 userspace WireGuard，避免 native `ip6tables` 初始化失败阻止启动。

`up` 添加的参数会持久化到 `config.json`，并在（重新）连接时生效，因此
修改后需要先执行 `netbird.service down`、再执行 `netbird.service up`
（或直接 `netbird.service restart`）。

状态监视线程会在每个刷新周期（默认 60 秒）重新应用 Android root 的 IPv4/IPv6 underlay 路由规则，
因此 Wi-Fi/蜂窝/双卡网络切换不再需要手动重启。同一监视线程还会在每个周期探测
daemon 健康，连续 3 次探测无响应即自动重启（看门狗：预算 10 次，连续 5 个
健康周期后重置——可用 `NB_WATCHDOG*` 调整，`NB_WATCHDOG=off` 关闭）。
`netbird.service stop`（以及卸载）会清除模块添加的所有 ip 规则和 iptables 规则。

## 动态状态

daemon 运行期间会定期刷新 `module.prop`。由于模块描述是单行元数据，状态
以紧凑的成对字段显示：IP/对等节点、管理/信号、中继/接口、内存、CA 数量
和刷新时间。对等节点字段带直连/中转统计（`[P3 R1]` = 3 直连、1 中转）；
`WD=n` 表示看门狗累计重启次数。

## 自定义 CA 信任

对于使用私有 CA 的自托管 NetBird 服务器，将 PEM 证书以 `.crt`、`.pem`
或 `.cer` 后缀放到 `/data/adb/netbird/certs/` 中。`/data/adb/netbird/ca.crt`
也会被自动加载。更换证书后重启 NetBird：

```sh
su -c 'netbird.service restart'
su -c '/data/adb/netbird/scripts/cert-trust.sh status'
```

模块会为 Linux 二进制运行时注入 `/system/etc/resolv.conf`。这不会改变
Android 普通应用的 DNS；`netbird.service up` 仍会通过 `--disable-dns`
关闭 NetBird 的 DNS 管理。

直接调用 NetBird 命令时应带上模块的 daemon 地址：

```sh
su -c 'netbird --daemon-addr unix:///data/adb/netbird/run/netbird.sock status'
```
