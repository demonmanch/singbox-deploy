# Sing-box 多协议一键部署脚本

> ## 🔧 本 Fork（demonmanch/singbox-deploy）的修复说明
>
> 一键安装（使用本 fork）：
>
> ```bash
> bash -c "$(curl -fsSL https://raw.githubusercontent.com/demonmanch/singbox-deploy/main/install-singbox-yyds.sh)"
> ```
>
> 修复 `install-singbox-yyds.sh` 中 `sb` 菜单「生成线路机脚本(出口为本机ss协议)」的问题（在 Alpine 3.21 LXC NAT 小鸡上实际踩坑）：
>
> - **SS 密码不一致**：生成线路机脚本时，SS 端口/加密方式/密码直接从 `/etc/sing-box/config.json` 中实际生效的 SS 入站（优先 tag `ss-in`）读取，不再使用可能过期的缓存；缓存写入改为「替换已有键」，不再重复追加 `SS_PSK=` 等旧值。
> - **入口IP vs 出口IP**：NAT/转发机上自动检测到的公网 IP 通常是**出口IP**（例如落地机出口是 SoftBank 126.x，而连接用的是香港转发入口 45.x），用它生成线路机脚本会连不上。现在会明确提示并要求填写**商家提供的入口IP/连接地址（通常就是 SSH 登录用的 IP）**；检测到的 IP 只作参考，回车使用它需要再次 y 确认；已保存的 `CUSTOM_IP` 作为默认值。
> - **地址校验**：落地机地址只接受 IPv4 / IPv6 / 域名，拒绝纯数字（如误填端口 `12345`）并重新输入；生成前显示汇总（地址、端口、加密方式、打码的密码）并 y/N 确认，可改填其他 IP。
> - **NAT 端口**：NAT 机器上 SS 端口必须是商家映射给你的端口之一，提示和汇总里都会提醒。
> - **线路机脚本**：覆盖线路机已有 `/etc/sing-box/config.json` 前自动备份为 `config.json.bak.时间戳` 并给出警告；配置改用 jq 生成，密码含特殊字符也不会出错；补充 SS 入站时加密方式与变量一致（默认仍为 aes-128-gcm），并校验配置、失败自动还原。
> - **节点名称/备注**：线路机安装时可设置 vless 链接 `#` 后的节点名称（默认 `中转-线路机IP`，支持中文/空格，自动 URL 编码）。之后可随时修改，只重新生成链接和 `/etc/sing-box/relay_uri.txt`，不动运行中的配置：
>   - `bash /root/relay-install.sh rename`（或 `bash /etc/sing-box/relay-install.sh rename`）
>   - `bash /root/relay-install.sh show` 查看链接
>   - 已安装过时直接运行脚本会出现菜单：1. 重新安装 2. 修改节点名称 3. 查看链接
> - **一条命令部署线路机**：落地机执行 `sb` → 选「生成线路机脚本」后，脚本保存在落地机 `/root/relay-install.sh`（权限 600），默认不再刷屏输出整个脚本，而是给出分步说明和两种整行复制的方法：
>   - 生成时会询问「落地机的 SSH 连接端口」（就是平时 SSH 登录落地机用的端口；NAT 机器填商家映射的端口，例如 45466，而不是机器内部的 22），保存为 `LANDING_SSH_PORT`，下次回车即沿用
>   - 方法一（推荐，在线路机整行执行；线路机没有 ssh 客户端会先自动安装 openssh-client，bash/ash 均可）：
>     `command -v ssh >/dev/null 2>&1 || { if command -v apk >/dev/null 2>&1; then apk add --no-cache openssh-client; elif command -v apt-get >/dev/null 2>&1; then apt-get update -y && apt-get install -y openssh-client; else yum install -y openssh-clients; fi; }; ssh -p <落地机SSH端口> root@<落地机入口IP> "cat /root/relay-install.sh" > /root/relay-install.sh && bash /root/relay-install.sh`
>     （首次连接输入 yes，再输入落地机 root 密码，输入时不显示）
>   - 方法二：输出最后一行的 `echo '<base64>' | base64 -d > /root/relay-install.sh && bash /root/relay-install.sh`，整行复制到线路机执行即可
>   - 运行时端口/名称直接回车用默认值；把得到的 vless:// 链接导入 Shadowrocket，无需设置「代理通过」；记得在线路机云厂商安全组（如 Oracle）放行监听端口
>   - 如需查看完整脚本，生成时在「是否显示完整脚本内容?(y/N)」处输入 y


一个强大的 Sing-box 自动化部署工具，支持SS/HY2/TUIC/VLESS Reality/AnyTLS Reality 协议自选部署和线路机 VLESS Reality 中转的完整解决方案。

---

## ✨ 主要特性

### 🎯 部署机功能

- ✅ **一键安装** - 自动部署 Sing-box 最新服务端
- ✅ **自动生成** - 自动生成 密钥和配置文件，Reality 自选或默认SNI
- ✅ **多系统支持** - 支持 Alpine, Debian, Ubuntu, CentOS, RHEL, Fedora 等操作系统
- ✅ **开机自启** - 自动配置 Systemd / OpenRC 开机自启，崩溃自动拉起服务端
- ✅ **连接 IP** - 自动获取公网 IP 或手动输入 连接IP/DDNS域名 并生成客户端链接
- ✅ **管理工具** - 输入 sb 指令进入管理界面查看节点链接、重置端口、服务端控制查看等功能

### 🔗 线路机功能

- ✅ **一键生成** - 从落地机直接生成线路机安装脚本
- ✅ **Reality 入站** - 自动部署 VLESS Reality 入站
- ✅ **灵活端口** - 支持自动寻找空闲端口或手动指定
- ✅ **流量转发** - 自动转发流量到落地机SS节点
- ✅ **完整链接** - 生成可用的 VLESS Reality 客户端链接

## 🙏 特别鸣谢以下商家对本项目的赞助支持

<div align="center">

<table>
  <tr>
    <td align="center" width="220">
      <a href="https://app.kaze.network/" target="_blank">
        <img src="https://app.kaze.network/templates/lagom2/assets/img/logo/logo_big.634794647.svg" width="100" alt="Kaze" />
        <br><sub><b>Kaze</b></sub>
      </a>
    </td>
    <td align="center" width="220">
      <a href="https://yuusei.io/" target="_blank">
        <img src="https://github.com/caigouzi121380/singbox-deploy/blob/main/yuu.svg" width="100" alt="Yuusei Network" />
        <br><sub><b>Yuusei Network</b></sub>
      </a>
    </td>
    <td align="center" width="220">
      <a href="https://lxc.lazycat.wiki" target="_blank">
        <img src="https://lxc.lazycat.wiki/upload/logo2.png" width="100" alt="懒猫云" />
        <br><sub><b>懒猫云</b></sub>
      </a>
  

  </tr>
</table>

</div>

## ✅ 一键部署命令

安装全功能 sing-box：

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/demonmanch/singbox-deploy/main/install-singbox-yyds.sh)"
