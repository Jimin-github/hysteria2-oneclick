# Hysteria 2 一键恢复脚本

面向 Debian 11+ 或 Ubuntu 22.04+ 的安全一键部署脚本。需要 systemd 和公网 IPv4。

脚本会自动：

- 从 Hysteria 官方更新 API 获取当前稳定版本；
- 从官方 GitHub Release 下载二进制，并校验发布方 SHA-256；
- 创建低权限 `hysteria` 服务账户；
- 配置 Let's Encrypt HTTP-01 自动证书；
- 将 QUIC UDP 缓冲上限调整为 64 MiB；
- 启用并启动 `hysteria-server.service`；
- 生成 `/root/hysteria2-clash.yaml`；
- 生成 `/root/hysteria2-hiddify.txt`（Base64 订阅文件）。

## 前提

1. 域名 A 记录已经指向新服务器公网 IPv4，且没有开启 CDN 代理。
2. 安全组放行 TCP 80 和 UDP 443。
3. TCP 80 与 UDP 443 没有被其他服务占用。
4. 使用全新服务器。脚本发现任何目标文件已存在时会停止，不会覆盖已有安装。

## 一行安装

```bash
wget -qO- 'https://raw.githubusercontent.com/Jimin-github/hysteria2-oneclick/main/install-hysteria2.sh' | bash -s -- '你的域名' '你的邮箱@example.com'
```

邮箱可以留空：

```bash
wget -qO- 'https://raw.githubusercontent.com/Jimin-github/hysteria2-oneclick/main/install-hysteria2.sh' | bash -s -- '你的域名'
```

可通过环境变量调整 Clash 中的 Brutal 带宽与服务端口：

```bash
wget -qO- 'https://raw.githubusercontent.com/Jimin-github/hysteria2-oneclick/main/install-hysteria2.sh' | HY2_UP_MBPS=100 HY2_DOWN_MBPS=500 HY2_PORT=443 bash -s -- '你的域名' '你的邮箱@example.com'
```

为获得更强的供应链固定性，可将 URL 中的 `main` 替换为你审阅过的具体提交哈希。

`up/down` 不会写进 Hiddify TXT。Hysteria 2 官方 URI 规范规定带宽属于客户端本地设置，不应放入分享 URI。

## 输出文件

```text
/root/hysteria2-clash.yaml
/root/hysteria2-hiddify.txt
```

两个客户端文件均包含节点认证密码，权限为 `0600`。请通过 SFTP/SCP 下载，不要上传到公开仓库或聊天记录。

## 删除行为

脚本不会删除或覆盖任何已有目标文件。运行期间会创建一个私有临时目录，并在退出时仅删除这个由本次运行创建的临时目录。
