# cloudflare-ddns

shell use api update cloudflare dns a aaaa

仅需要设置登录邮箱，global_api_key即可

其他的都由脚本自动获取

写的不好，凑活用吧。

6是更新ipv6地址AAAA记录

4是更新ipv4地址A记录

cloudflardCheck "domain.com" "www" 6

cloudflardCheck "domain.com" "www" 4

freenom的域名，已不可以通过API，脚本更新，只能去web手动更新。

难道再写个爬虫搞他么？
