# cloudflare-ddns
一个用于cloudflare ddns的shell脚本。
使用curl jq 来实现。

已实现：
自动生成配置文件
从互联网或本地设置获取IP。
多个主机，多个网卡，仅一次性获取IP。
同时比较IP和代理状态。

todo：
自定义配置文件名
自动安装依赖
优化CURL请求
自动注册不存在的主机

自动识别linux openwrt?

A shell script for cloudflare ddns.
Use curl jq to implement.

Implemented:
Automatically generate configuration files
Obtain IP from Internet or local settings.
Multiple hosts, multiple network cards, only obtaining IP at once.
Compare IP and proxy status simultaneously.

Todo:
Custom configuration file name
Automatic installation dependency
Optimize CURL requests
Automatically register non-existent hosts

Automatically recognize Linux openwrt?

