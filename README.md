# Shadowsocks 安装脚本

在 **Linux 服务器**（Ubuntu / Debian 等）上以 root 执行。先下载脚本，再按场景运行。

脚本地址：

```text
https://raw.githubusercontent.com/lichen930122-lang/ss-install/main/shadowsocks.sh
```

账号密码会显示在屏幕上，同时写入：

- 当前目录 `shadowsocks.log`
- `/root/shadowsocks-users.txt`

云厂商安全组要放行你选的端口（**TCP + UDP**）。

---

## 1. 新机器，第一次装（空系统）

完整复制这三行，不要漏最后一行：

```bash
wget -O shadowsocks.sh https://raw.githubusercontent.com/lichen930122-lang/ss-install/main/shadowsocks.sh
chmod +x shadowsocks.sh
./shadowsocks.sh 2>&1 | tee shadowsocks.log
```

然后按提示选：

1. 服务端程序：回车默认「根据系统自动选择」；也可指定 rust 或 libev
2. 部署方式：`1` 单端口单用户，`2` 多端口多人（一人一端口一把密码）
3. 转发模式：回车默认 `TCP + UDP`
4. 若选多人：人数、起始端口（回车则随机）、加密方式
5. 是否「每端口同时只允许 1 个公网 IP」（独享）
6. 最后确认：输入 `y` 才真正安装

**不要**在空系统上跑 `limit-on`。那是给已经装好的机器补独享用的。

示例（多用户 10 人、独享）：

```text
0) 服务端程序 → 回车（自动选择）
0) 部署方式 → 2
1) 转发模式 → 回车（tcp_and_udp）
2) 用户数量 → 10
3) 起始端口 → 例如 23859（连续 10 个用户口）或回车随机
4) 加密方式 → 回车（chacha20-ietf-poly1305）
5) 每端口同时在线限制 → 回车（1 个公网 IP）
确认执行 → y
```

装完看 `/root/shadowsocks-users.txt`：`链接` 给 Shadowrocket；独享时还有 `Airlink` 一行（`ss://...?spki=...`），导入 Airlink 会自动带上登记指纹。普通客户端不要用 Airlink 那行。云安全组放行业务口 **TCP+UDP**，以及 **TCP 443**。

---

## 2. 已经装好了，只是独享没开

机器上如果已经有 `shadowsocks.sh`：

```bash
./shadowsocks.sh limit-on
```

没有脚本、或想用 GitHub 上最新一份时，三行一起跑：

```bash
wget -O shadowsocks.sh https://raw.githubusercontent.com/lichen930122-lang/ss-install/main/shadowsocks.sh
chmod +x shadowsocks.sh
./shadowsocks.sh limit-on
```

不改端口、不改密码，只补开「每端口同时 1 个公网 IP」。

若提示没有 `iptables`：

```bash
apt-get update
apt-get install -y iptables ipset python3
./shadowsocks.sh limit-on
```

---

## 3. 已经装好了，想关掉独享（同一密码可多人同时连）

```bash
./shadowsocks.sh limit-off
```

或重新下载后再关：

```bash
wget -O shadowsocks.sh https://raw.githubusercontent.com/lichen930122-lang/ss-install/main/shadowsocks.sh
chmod +x shadowsocks.sh
./shadowsocks.sh limit-off
```

服务继续跑，只关限制。

---

## 4. 已经装好了，想重装 / 改人数、端口、密码、加密

和第一次安装同一条命令，会重新走交互，确认 `y` 后覆盖配置，**旧密码作废**：

```bash
wget -O shadowsocks.sh https://raw.githubusercontent.com/lichen930122-lang/ss-install/main/shadowsocks.sh
chmod +x shadowsocks.sh
./shadowsocks.sh 2>&1 | tee shadowsocks.log
```

若当前目录已经有可执行的 `shadowsocks.sh`，也可以只跑：

```bash
./shadowsocks.sh 2>&1 | tee shadowsocks.log
```

---

## 5. 卸载干净

```bash
./shadowsocks.sh uninstall
```

或：

```bash
wget -O shadowsocks.sh https://raw.githubusercontent.com/lichen930122-lang/ss-install/main/shadowsocks.sh
chmod +x shadowsocks.sh
./shadowsocks.sh uninstall
```

---

## 对照

| 机器状态 | 实际要跑的命令 |
|---|---|
| 新机器、空系统 | `wget` + `chmod` + `./shadowsocks.sh 2>&1 \| tee shadowsocks.log` |
| 已装好，补独享 | `./shadowsocks.sh limit-on` |
| 已装好，关独享 | `./shadowsocks.sh limit-off` |
| 已装好，整机重配 | 同第一次安装那三行（或已有脚本时只跑 `./shadowsocks.sh`） |
| 不要了 | `./shadowsocks.sh uninstall` |
