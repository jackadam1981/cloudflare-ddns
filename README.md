# cloudflare-ddns

一个用于cloudflare ddns的shell脚本。
使用curl jq 来实现。


查看日志

journalctl --no-pager --since today -g 'DDNS'

logread -e DDNS

已实现：


自动生成配置文件。
    默认配置文件名：cfconf.json


任意配置文件名。
    使用方法：
    ./cfddns.sh -c 配置文件名

-
从互联网或本地设置获取IP。
    默认获取方式：
        互联网：curl -s https://api.ipify.org?format=json | jq -r '.ip'
        本地设置：ip -4 addr show br-lan | grep 'inet' | awk '{print $2}' | cut -d/ -f1
    配置方式：
        json配置文件中"static"字段，设置为true时，使用本地设置获取IP。


同时比较IP和代理状态。
    配置方式：
        json配置文件中"proxy"字段，设置为true时，使用代理获取IP。


任意域名，任意子域名，任意网卡，任意IP类型。
    配置方式：
        json配置文件中"domain_name"字段，设置为域名。
        json配置文件中"records"字段，设置为子域名。
        json配置文件中"nic_name"字段，设置为网卡名。
        json配置文件中"type"字段，设置为IP类型。


自动注册不存在的主机。
    无需配置，自动注册。

todo：
优化IP获取，动态存储需要的IP地址。
    希望在使用相同网络参数获取IP时，动态存储IP地址。
    当使用相同网络参数再次获取IP时，先检查IP是否存在，不存在则再次获取。

自动安装依赖
    自动安装curl jq

自动识别linux openwrt?
    sh bash，不一样，无法自动识别。
