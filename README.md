# ss-install

在任意 Ubuntu / Debian VPS 上交互安装 Shadowsocks-libev。

```bash
wget -O shadowsocks.sh https://raw.githubusercontent.com/lichen930122-lang/ss-install/main/shadowsocks.sh
chmod +x shadowsocks.sh
./shadowsocks.sh 2>&1 | tee shadowsocks.log
```

卸载：

```bash
./shadowsocks.sh uninstall
```
