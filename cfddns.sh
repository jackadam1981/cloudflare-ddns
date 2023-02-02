#!/bin/sh

# Import ardnspod functions
. ./cloudflareDdns

login_email=jack@***.com
Global_API_Key=11111111b9179ca223b3a8309afd4cab0533c
# 检查环境
check_environment
#检查token
check_token

cloudflardCheck "domain.com" "www" 6
cloudflardCheck "domain.com" "www" 4
