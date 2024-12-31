#!/bin/bash

# 系统检测模块
detect_system() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            "ubuntu"|"debian")
                service_manager="systemctl"
                ;;
            "centos")
                if [ "$VERSION_ID" -ge 7 ]; then
                    service_manager="systemctl"
                else
                    service_manager="service"
                fi
                ;;
            *)
                echo "不支持的系统"
                return 1
                ;;
        esac
    else
        echo "无法识别的系统"
        return 1
    fi
}

# 软件安装模块
check_and_install_unzip() {
    if ! command -v unzip &> /dev/null; then
        echo "未安装unzip，正在安装..."
        if [ "$ID" == "centos" ]; then
            sudo yum install unzip -y
        else
            sudo apt-get install unzip -y
        fi
    fi
    return 0
}

# Xray 安装函数
install_xray() {
    echo "正在从GitHub下载Xray..."
    check_and_install_unzip
    
    # 创建临时目录
    mkdir -p /tmp/xray
    cd /tmp/xray
    
    # 下载最新版本
    echo "下载Xray..."
    wget --no-check-certificate -O xray.zip "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"
    
    if [ $? -ne 0 ]; then
        echo "下载失败，请检查网络连接"
        return 1
    fi
    
    # 解压
    echo "解压文件..."
    unzip -o xray.zip
    
    # 移动文件
    echo "安装Xray..."
    mv xray /usr/local/bin/
    chmod +x /usr/local/bin/xray
    
    # 创建配置目录
    mkdir -p /etc/xray
    mkdir -p /var/log/xray
    
    # 清理临时文件
    cd /
    rm -rf /tmp/xray
    
    echo "Xray安装完成"
    return 0
}

# 环境配置模块
setup_environment() {
    echo "设置防火墙规则..."
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT
    iptables -t nat -F
    iptables -t mangle -F
    iptables -F
    iptables -X
    iptables-save

    # 安装 Xray
    install_xray
    
    echo "创建Xray服务文件..."
    cat <<EOF > /etc/systemd/system/xray.service
[Unit]
Description=The Xray Proxy Server
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /etc/xray/serve.toml
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

    echo "启动Xray服务..."
    systemctl daemon-reload
    systemctl enable xray
    systemctl start xray
    echo "环境配置完成。"
    return 0
}

# 代理设置模块
set_socks5_credentials() {
    read -p "请输入SOCKS5端口: " socks_port
    read -p "请输入用户名: " socks_user
    read -p "请输入密码: " socks_pass
    configure_xray "$socks_port" "$socks_user" "$socks_pass"
    generate_proxy_list "$socks_port" "$socks_user" "$socks_pass"
    echo "SOCKS5端口、用户名和密码设置完成。"
    return 0
}

configure_xray() {
    echo "配置Xray..."
    mkdir -p /etc/xray
    echo -n "" > /etc/xray/serve.toml
    local ips=($(hostname -I))
    for ((i = 0; i < ${#ips[@]}; i++)); do
        cat <<EOF >> /etc/xray/serve.toml
[[inbounds]]
listen = "${ips[i]}"
port = $1
protocol = "socks"
tag = "$((i+1))"
[inbounds.settings]
auth = "password"
udp = true
ip = "${ips[i]}"
[[inbounds.settings.accounts]]
user = "$2"
pass = "$3"
[[routing.rules]]
type = "field"
inboundTag = "$((i+1))"
outboundTag = "$((i+1))"
[[outbounds]]
sendThrough = "${ips[i]}" 
protocol = "freedom" 
tag = "$((i+1))"

EOF
    done
    echo "Xray配置已完成。"
    return 0
}
# 代理管理模块
generate_proxy_list() {
    local socks_port=$1
    local socks_user=$2
    local socks_pass=$3
    local ips=($(hostname -I))
    echo "生成代理列表文件..."
    echo -n "" > /root/proxy_list.txt
    for ip in "${ips[@]}"; do
        echo "$ip:$socks_port:$socks_user:$socks_pass" >> /root/proxy_list.txt
    done
    echo "代理列表文件已生成：/root/proxy_list.txt"
    return 0
}

clear_proxy_rules() {
    echo "清除所有代理规则..."
    $service_manager stop xray
    $service_manager disable xray
    rm -f /etc/xray/serve.toml
    rm -f /etc/systemd/system/xray.service
    iptables -F
    iptables -X
    iptables -t nat -F
    iptables -t mangle -F
    ip6tables -F
    ip6tables -X
    ip6tables -t nat -F
    ip6tables -t mangle -F
    iptables-save
    ip6tables-save
    rm -f /root/proxy_list.txt
    echo "已清除所有代理规则，回到未安装SOCKS5代理的状态。"
    return 0
}

test_proxy_connectivity() {
    echo "测试代理连通性..."
    
    if [ ! -f /root/proxy_list.txt ]; then
        echo "/root/proxy_list.txt 文件不存在。"
        return 1
    fi

    # 检查 xray 服务状态
    echo "检查 Xray 服务状态..."
    if ! systemctl is-active --quiet xray; then
        echo "错误: Xray 服务未运行"
        systemctl status xray
        return 1
    fi

    while IFS= read -r line; do
        if [[ $line =~ ^(.+):([0-9]+):(.+):(.+)$ ]]; then
            ip="${BASH_REMATCH[1]}"
            port="${BASH_REMATCH[2]}"
            user="${BASH_REMATCH[3]}"
            pass="${BASH_REMATCH[4]}"
            
            echo "正在测试 $ip:$port..."
            echo "使用凭据: $user:$pass"
            
            if [[ $ip == *:* ]]; then
                ip="[$ip]"
            fi

            # 添加详细的 curl 输出
            echo "尝试连接..."
            curl_output=$(curl -v --proxy socks5h://$user:$pass@$ip:$port http://httpbin.org/ip 2>&1)
            curl_status=$?

            if [ $curl_status -eq 0 ]; then
                echo "代理连接成功: $ip:$port"
                echo "返回的 IP 信息:"
                echo "$curl_output" | grep -A 2 "origin"
            else
                echo "代理连接失败: $ip:$port"
                echo "错误详情:"
                echo "$curl_output"
                
                # 检查本地端口是否在监听
                echo "检查端口 $port 是否在监听..."
                if netstat -tuln | grep -q ":$port "; then
                    echo "端口 $port 正在监听"
                else
                    echo "错误: 端口 $port 未在监听"
                fi
                
                # 检查防火墙规则
                echo "检查防火墙规则..."
                iptables -L -n | grep $port
            fi
            
            echo "----------------------------"
        else
            echo "行格式不正确: $line"
        fi
    done < /root/proxy_list.txt

    echo "代理连通性测试完成。"
    
    # 显示 Xray 日志
    echo "最近的 Xray 日志:"
    journalctl -u xray --no-pager -n 50
    
    return 0
}

# 自动检测所有活动网络接口
get_active_interfaces() {
    interfaces=$(ip -o link show | awk -F': ' '{print $2}' | grep -v 'lo')
    echo "检测到的活动网络接口: $interfaces"
    return 0
}

# 获取当前活动的IP数量
get_active_ip_count() {
    active_ip_count=$(ss -H -t state established | awk '{print $5}' | cut -d: -f1 | sort | uniq | wc -l)
    echo "当前活动的IP数量: $active_ip_count"
    return 0
}

# 带宽管理模块
setup_bandwidth_control() {
    get_active_interfaces
    get_active_ip_count

    read -p "请输入VPS的总带宽（例如50M）: " total_bandwidth

    if [[ ! $total_bandwidth =~ ^[0-9]+M$ ]]; then
        echo "ERROR: 输入格式错误，请输入类似'50M'的格式。"
        return 1
    fi

    if [ "$active_ip_count" -eq 0 ]; then
        echo "INFO: 没有活动的IP，跳过带宽设置。"
        return 0
    fi

    local rate=$(echo "${total_bandwidth%M} / $active_ip_count" | bc)Mbit

    echo "INFO: 设置带宽控制..."
    for interface in $interfaces; do
        tc qdisc del dev $interface root 2>/dev/null
        tc qdisc add dev $interface root handle 1: htb default 30
        tc class add dev $interface parent 1: classid 1:1 htb rate $total_bandwidth

        for ip in $(hostname -I); do
            tc class add dev $interface parent 1:1 classid 1:10 htb rate ${rate} ceil ${rate}
            tc filter add dev $interface protocol ip parent 1:0 prio 1 u32 match ip dst $ip flowid 1:10
        done
    done

    echo "INFO: 带宽控制设置完成。"
    return 0
}

# 启用BBR
enable_bbr() {
    echo "启用BBR..."
    
    if ! sysctl net.ipv4.tcp_available_congestion_control | grep -q "bbr"; then
        echo "当前内核不支持BBR，请升级内核。"
        return 1
    fi

    echo "net.core.default_qdisc=fq" | sudo tee -a /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" | sudo tee -a /etc/sysctl.conf

    sudo sysctl -p

    if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        echo "BBR已成功启用。"
    else
        echo "BBR启用失败，请检查配置。"
    fi
    return 0
}

# 设置IP进出策略
set_ip_strategy() {
    echo "配置IP进出策略..."
    
    # 获取IPv4和IPv6地址列表
    ipv4_addrs=($(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1'))
    ipv6_addrs=($(ip -6 addr show | grep -oP '(?<=inet6\s)[\da-f:]+' | grep -v '^fe80'))
    
    echo "当前IPv4地址: ${ipv4_addrs[@]}"
    echo "当前IPv6地址: ${ipv6_addrs[@]}"
    
    echo "请选择IP进出策略："
    echo "1. 同IP进同IP出（默认）"
    echo "2. IPv4进随机IPv4出（每个请求随机切换，不重复直到用完）"
    echo "3. IPv4进随机IPv6出（每个请求随机切换，不重复直到用完）"
    read -p "请输入选项 [1-3]: " strategy

    # 创建配置目录
    mkdir -p /etc/xray
    mkdir -p /etc/xray/track

    case $strategy in
        1)
            # 同IP进出策略保持不变
            ...
            ;;
        2)
            echo "设置IPv4进随机IPv4出..."
            # 创建状态跟踪文件
            cat <<EOF > /etc/xray/track/ipv4_state.json
{
    "last_used": "",
    "used_ips": []
}
EOF
            
            # 生成配置文件
            cat <<EOF > /etc/xray/serve.toml
{
    "log": {
        "loglevel": "debug"
    },
    "inbounds": [
        {
            "listen": "0.0.0.0",
            "port": $socks_port,
            "protocol": "socks",
            "tag": "inbound",
            "settings": {
                "auth": "password",
                "udp": true,
                "accounts": [
                    {
                        "user": "$socks_user",
                        "pass": "$socks_pass"
                    }
                ]
            }
        }
    ],
    "outbounds": [
EOF

            # 添加所有IPv4出站
            first=true
            for ip in "${ipv4_addrs[@]}"; do
                if [ "$first" = true ]; then
                    first=false
                else
                    echo "," >> /etc/xray/serve.toml
                fi
                cat <<EOF >> /etc/xray/serve.toml
        {
            "protocol": "freedom",
            "tag": "out_$ip",
            "settings": {
                "domainStrategy": "UseIPv4"
            },
            "sendThrough": "$ip"
        }
EOF
            done

            # 添加负载均衡器和路由规则
            cat <<EOF >> /etc/xray/serve.toml
    ],
    "routing": {
        "balancers": [
            {
                "tag": "ipv4_balancer",
                "selector": [
EOF

            # 添加所有IPv4选择器
            first=true
            for ip in "${ipv4_addrs[@]}"; do
                if [ "$first" = true ]; then
                    first=false
                else
                    echo "," >> /etc/xray/serve.toml
                fi
                echo "                    \"out_$ip\"" >> /etc/xray/serve.toml
            done

            cat <<EOF >> /etc/xray/serve.toml
                ],
                "strategy": {
                    "type": "random",
                    "settings": {
                        "nonRepeat": true,
                        "stateFile": "/etc/xray/track/ipv4_state.json",
                        "resetInterval": "0"
                    }
                }
            }
        ],
        "rules": [
            {
                "type": "field",
                "network": "tcp,udp",
                "balancerTag": "ipv4_balancer"
            }
        ]
    }
}
EOF
            ;;
        3)
            echo "设置IPv4进随机IPv6出..."
            # 创建状态跟踪文件
            cat <<EOF > /etc/xray/track/ipv6_state.json
{
    "last_used": "",
    "used_ips": []
}
EOF
            
            # 生成配置文件
            cat <<EOF > /etc/xray/serve.toml
{
    "log": {
        "loglevel": "debug"
    },
    "inbounds": [
        {
            "listen": "0.0.0.0",
            "port": $socks_port,
            "protocol": "socks",
            "tag": "inbound",
            "settings": {
                "auth": "password",
                "udp": true,
                "accounts": [
                    {
                        "user": "$socks_user",
                        "pass": "$socks_pass"
                    }
                ]
            }
        }
    ],
    "outbounds": [
EOF

            # 添加所有IPv6出站
            first=true
            for ip in "${ipv6_addrs[@]}"; do
                if [ "$first" = true ]; then
                    first=false
                else
                    echo "," >> /etc/xray/serve.toml
                fi
                cat <<EOF >> /etc/xray/serve.toml
        {
            "protocol": "freedom",
            "tag": "out_$ip",
            "settings": {
                "domainStrategy": "UseIPv6"
            },
            "sendThrough": "$ip"
        }
EOF
            done

            # 添加负载均衡器和路由规则
            cat <<EOF >> /etc/xray/serve.toml
    ],
    "routing": {
        "balancers": [
            {
                "tag": "ipv6_balancer",
                "selector": [
EOF

            # 添加所有IPv6选择器
            first=true
            for ip in "${ipv6_addrs[@]}"; do
                if [ "$first" = true ]; then
                    first=false
                else
                    echo "," >> /etc/xray/serve.toml
                fi
                echo "                    \"out_$ip\"" >> /etc/xray/serve.toml
            done

            cat <<EOF >> /etc/xray/serve.toml
                ],
                "strategy": {
                    "type": "random",
                    "settings": {
                        "nonRepeat": true,
                        "stateFile": "/etc/xray/track/ipv6_state.json",
                        "resetInterval": "0"
                    }
                }
            }
        ],
        "rules": [
            {
                "type": "field",
                "network": "tcp,udp",
                "balancerTag": "ipv6_balancer"
            }
        ]
    }
}
EOF
            ;;
    esac

    # 重启 Xray 服务
    systemctl daemon-reload
    systemctl restart xray
    
    echo "IP策略设置完成。"
    echo "正在检查 Xray 服务状态..."
    sleep 2
    systemctl status xray
    
    return 0
}

# 菜单模块
show_menu() {
    echo "请选择要执行的操作："
    echo "1. 环境配置"
    echo "2. SOCKS5代理设置"
    echo "3. 显示代理列表"
    echo "4. 清除所有代理规则"
    echo "5. 测试代理连通性"
    echo "6. 设置带宽控制"
    echo "7. 启用BBR"
    echo "8. 设置IP进出策略"
    echo "9. 退出"
    read -p "请输入选项 [1-9]: " option
    case $option in
        1) setup_environment ;;
        2) set_socks5_credentials ;;
        3) cat /root/proxy_list.txt ;;
        4) clear_proxy_rules ;;
        5) test_proxy_connectivity "${socks_port}" "${socks_user}" "${socks_pass}" ;;
        6) setup_bandwidth_control ;;
        7) enable_bbr ;;
        8) set_ip_strategy ;;
        9) echo "退出脚本。"; exit ;;
        *) echo "无效选项，请输入1-9之间的数字" ;;
    esac
    return 0
}

# 主程序
detect_system
check_and_install_iptables
while true; do
    show_menu
    sleep 60
done
