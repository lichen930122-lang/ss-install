# Shadowsocks 安装脚本

所有情况都先用同一份脚本：

```bash
wget -O shadowsocks.sh https://raw.githubusercontent.com/lichen930122-lang/ss-install/main/shadowsocks.sh
chmod +x shadowsocks.sh
```

后面按场景选一条。

## 1. 新机器，第一次装（空系统）

```bash
./shadowsocks.sh 2>&1 | tee shadowsocks.log
```

交互选完后确认 `y`。账号密码会打在屏幕上，并写进 `shadowsocks.log` 和 `/root/shadowsocks-users.txt`。

不要在空系统上跑 `limit-on`。

## 2. 已经装好了，只是独享没开

```bash
./shadowsocks.sh limit-on
```

不改端口、不改密码，只补开「每端口同时 1 个公网 IP」。

如果提示没有 `iptables`，先装再开：

```bash
apt-get update
apt-get install -y iptables ipset python3
./shadowsocks.sh limit-on
```

## 3. 已经装好了，想关掉独享（允许同一密码多人同时连）

```bash
./shadowsocks.sh limit-off
```

服务继续跑，只关限制。

## 4. 已经装好了，想重装 / 改人数、端口、密码、加密

```bash
./shadowsocks.sh 2>&1 | tee shadowsocks.log
```

和第一次安装同一条。确认 `y` 后会覆盖配置，**旧密码作废**。

## 5. 卸载干净

```bash
./shadowsocks.sh uninstall
```

## 对照

| 机器状态 | 命令 |
|---|---|
| 新机器、空系统 | `./shadowsocks.sh` |
| 已装好，补独享 | `./shadowsocks.sh limit-on` |
| 已装好，关独享 | `./shadowsocks.sh limit-off` |
| 已装好，整机重配 | `./shadowsocks.sh` |
| 不要了 | `./shadowsocks.sh uninstall` |

云厂商安全组要放行你选的那些端口的 **TCP + UDP**。
