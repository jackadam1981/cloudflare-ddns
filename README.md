# DDNS 脚本说明

## 简介

`ddns.sh` 是一个用于动态更新 Cloudflare DNS 记录的脚本。它通过检查本地和公网 IP 地址，自动更新 Cloudflare 上的 DNS 记录，以确保域名解析到正确的 IP 地址。

## 功能

- 检查并安装必要的依赖工具（如 `jq` 和 `curl` 或 `wget`）。
- 解析配置文件 `cfconf.json`，获取域名和记录信息。
- 验证 Cloudflare API 的授权密钥。
- 获取并更新 Cloudflare 的 `zone_id`。
- 获取本地和公网 IP 地址。
- 创建或更新 Cloudflare DNS 记录。
- 自动设置 `crontab` 任务，每 10 分钟执行一次脚本。
- 自动生成示例配置文件。

## 使用方法

1. **配置文件**：确保在脚本目录下存在 `cfconf.json` 配置文件。可以通过命令行参数 `-c` 指定其他配置文件路径。如果配置文件不存在，脚本会自动生成一个示例配置文件。
2. **执行脚本**：直接运行脚本即可开始更新 DNS 记录。
3. **日志查看**：可以通过 `journalctl` 查看脚本的运行日志。

## 配置文件格式

`cfconf.json` 文件包含以下配置：

- **settings**：全局设置。

  - `log_level`：日志级别（如 `debug`, `info`, `warn`, `error`, `fatal`）。
  - `arIp6QueryUrl`：用于查询 IPv6 地址的 URL。
  - `arIp4QueryUrl`：用于查询 IPv4 地址的 URL。
  - `log_header_name`：日志头名称。
- **domains**：域名列表，每个域名包含以下信息：

  - `domain_name`：域名。
  - `zone_id`：Cloudflare 的区域 ID，初始为空，脚本会自动获取。
  - `auth_email`：Cloudflare 账户的电子邮件。
  - `auth_key`：Cloudflare API 授权密钥。
  - `auth_key_valid`：授权密钥是否有效，初始为 `false`，脚本会自动验证。
  - `records`：记录列表，每个记录包含以下信息：
    - `name`：子域名。
    - `type`：记录类型（如 `A`, `AAAA`）。
    - `proxy`：是否启用代理。
    - `local`：是否使用本地 IP。
    - `nic_name`：网络接口名称。

## 注意事项

- 确保 `jq` 已安装。
- 确保 `curl` 或 `wget` 至少安装其中之一。
- 确保 Cloudflare API 授权密钥有效。
- 确保网络连接正常，以便访问 Cloudflare API 和 IP 查询服务。

## TODO

- 使用sh脚本特性，替换jq。减少依赖项。
