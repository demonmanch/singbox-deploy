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
>   - 已安装过时直接运行脚本会出现菜单：1. 追加这台落地机为新的中转节点（回车默认） 2. 查看所有节点链接 3. 修改节点名称 4. 删除某个中转节点 5. 添加/删除直连节点 9. ⚠️ 全部重新安装 0. 退出
> - **可选：线路机直连节点**：线路机安装时会问「是否同时添加一个本机(线路机)直连出口的 VLESS Reality 节点? (y/N)」，默认 N（与以前完全一样）。选 y 后再输入直连端口（回车随机，不能与中转端口相同，已占用的端口会提示换一个）和名称（默认 `直连-<线路机IP>`），会多出一个 `vless-direct-in` 入站（独立 UUID，复用同一套 Reality 密钥/SNI/short_id）走线路机本机出口；中转入站仍走落地机。两条链接都写入 `/etc/sing-box/relay_uri.txt`，并分别标注「中转节点(出口落地机)」「直连节点(出口本机)」。之后可用 `bash /root/relay-install.sh direct`（或菜单 4）添加/删除直连节点，`rename` 可选择改哪个节点的名称。**记得在云安全组放行两个端口。**
> - **一条命令部署线路机**：落地机执行 `sb` → 选「生成线路机脚本(出口为本机ss协议)」（菜单编号随已启用的协议数量变化，例如只装了一个协议时是 10），脚本保存在落地机 `/root/relay-install.sh`（权限 600），默认不再刷屏输出整个脚本，而是给出分步说明和两种整行复制的方法：
>   - 生成时会询问「落地机的 SSH 连接端口」（就是平时 SSH 登录落地机用的端口；NAT 机器填商家映射的端口，例如 45466，而不是机器内部的 22），保存为 `LANDING_SSH_PORT`，下次回车即沿用
>   - 方法一（推荐，在线路机整行执行；线路机没有 ssh 客户端会先自动安装 openssh-client，bash/ash 均可）：
>     `command -v ssh >/dev/null 2>&1 || { if command -v apk >/dev/null 2>&1; then apk add --no-cache openssh-client; elif command -v apt-get >/dev/null 2>&1; then apt-get update -y && apt-get install -y openssh-client; else yum install -y openssh-clients; fi; }; ssh -p <落地机SSH端口> root@<落地机入口IP> "cat /root/relay-install.sh" > /root/relay-install.sh && bash /root/relay-install.sh`
>     （首次连接输入 yes，再输入落地机 root 密码，输入时不显示）
>   - 方法二：输出最后一行的 `echo '<base64>' | base64 -d > /root/relay-install.sh && bash /root/relay-install.sh`，整行复制到线路机执行即可
>   - 运行时端口/名称直接回车用默认值；把得到的 vless:// 链接导入 Shadowrocket，无需设置「代理通过」；记得在线路机云厂商安全组（如 Oracle）放行监听端口
>   - 如需查看完整脚本，生成时在「是否显示完整脚本内容?(y/N)」处输入 y
>
> ### 🔀 一台线路机中转多台落地机
>
> 同一台线路机可以同时中转多台落地机，每台落地机一个独立节点（独立端口和 UUID，复用同一套 Reality 密钥），互不影响：
>
> 1. 在**新的落地机**上 `sb` → 「生成线路机脚本(出口为本机ss协议)」，按提示用方法一或方法二在**线路机**上运行脚本。
> 2. 线路机上已有中转节点时会出现「线路机管理」菜单，**直接回车选「1) 追加这台落地机为新的中转节点」**，再回车用随机端口和默认名称（默认 `中转-落地<落地机IP>`），确认即可。原有节点的端口/UUID/链接都不变，不需要重新导入。
> 3. **在 Oracle 安全列表（Security List）放行新端口（TCP）**，脚本最后会用中文提示端口号；系统防火墙(ufw/firewalld/iptables)开着时会询问是否自动放行。
> 4. 把新节点那一行 vless:// 链接导入小火箭。所有链接都在线路机 `/etc/sing-box/relay_uri.txt`。
>
> - 每多一台落地机就重复一次上面的步骤；同一台落地机（同地址+端口）不会重复添加，若它的 SS 密码/加密方式变了会提示原地更新（链接不变）。
> - 以后在线路机运行 `bash /etc/sing-box/relay-install.sh` 管理（或带参数 `show` / `rename` / `delete` / `direct` / `append`）。
> - 旧版线路机（只有一个中转节点）第一次运行新脚本时会自动把原节点登记为「节点 1」，端口/UUID/链接不变。
> - 已经接入线路机的旧落地机**不需要**更新 `sb` 面板，只有用来生成新脚本的那台落地机需要更新。
> - 「9) 全部重新安装」会删除线路机上所有节点，需输入 `yes` 确认，只在想全部重来时使用。
>
> ### 📱 HY2 链接适配 v2rayNG（证书指纹 pinSHA256）
>
> v2rayNG 使用的 Xray 内核（26.2.6+）已移除 `allowInsecure`，旧的 `hy2://...&insecure=1` 链接在 v2rayNG 上会报错、无法连接。现在 HY2 链接会自动带上自签证书的 SHA-256 指纹：
>
> - **通用链接**（v2rayNG / Shadowrocket 都能用）：`hy2://密码@IP:端口/?sni=www.bing.com&alpn=h3&insecure=1&pinSHA256=<64位指纹>#hy2...`
> - **Shadowrocket 备用**（旧格式，名称带 `-SR-legacy`，v2rayNG 不可用）：电脑上已经导入的旧节点可以继续用，不必重新导入。
> - TUIC 链接不变（v2rayNG/Xray 不支持 TUIC）；线路机中转节点是 VLESS Reality，不受影响。
>
> **已安装的落地机只需更新 `sb` 面板（不重装、不改节点/端口/密码/证书）**，以 root 整行执行：
>
> ```bash
> curl -fsSL https://raw.githubusercontent.com/demonmanch/singbox-deploy/main/install-singbox-yyds.sh -o /tmp/sb-install.sh && awk '/<<.SB_SCRIPT.$/{f=1;next} /^SB_SCRIPT$/{f=0} f' /tmp/sb-install.sh > /tmp/sb.new && grep -q pinSHA256 /tmp/sb.new && bash -n /tmp/sb.new && cp /tmp/sb.new /usr/local/bin/sb && chmod +x /usr/local/bin/sb && ln -sf /usr/local/bin/sb /usr/bin/sb && rm -f /tmp/sb-install.sh /tmp/sb.new && echo "sb 面板已更新"
> ```
>
> 然后输入 `sb`，选 `1) 查看协议链接`，复制「通用链接」那一行。手机 v2rayNG：先长按删除旧的 hy2 节点，再复制新链接 → 右上角 `+` →「从剪贴板导入」，连接即可。


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
