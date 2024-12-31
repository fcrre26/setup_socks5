#!/bin/bash
#
# Xray SOCKS5 代理服务器安装脚本
# 版本：1.0
# 日期：2023-12-31
#
# 使用方法：
# 1. 给予执行权限：chmod +x setup_socks5.sh
# 2. 以root权限运行：sudo ./setup_socks5.sh
#

set -e  # 遇到错误立即退出
set -u  # 使用未定义的变量时报错

# 全局变量
socks_port=""
socks_user=""
socks_pass=""
service_manager=""

# 日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# 错误处理函数
handle_error() {
    log "错误: $1"
    return 1
}

# 权限检查
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo "此脚本需要root权限运行"
        exit 1
    fi
}

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
                handle_error "不支持的系统"
                return 1
                ;;
        esac
    else
        handle_error "无法识别的系统"
        return 1
    fi
}

# 检查并安装必要的软件包
check_and_install_packages() {
    log "检查并安装必要的软件包..."
    
    local packages=("curl" "wget" "unzip" "iptables" "net-tools")
    
    for pkg in "${packages[@]}"; do
        if ! command -v $pkg &> /dev/null; then
            log "安装 $pkg..."
            if [ "$ID" == "centos" ]; then
                yum install -y $pkg
            else
                apt-get update
                apt-get install -y $pkg
            fi
        fi
    done
}

# 配置文件检查
check_config() {
    if [ ! -f /etc/xray/serve.toml ]; then
        handle_error "配置文件不存在"
        return 1
    fi
    
    if ! /usr/local/bin/xray -test -config /etc/xray/serve.toml; then
        handle_error "配置文件验证失败"
        return 1
    fi
    return 0
}

# 清理函数
cleanup() {
    log "执行清理操作..."
    clear_proxy_rules
    rm -rf /tmp/xray
    log "清理完成"
}

# 设置信号处理
trap cleanup EXIT
# Xray 安装函数
install_xray() {
    log "正在从GitHub下载Xray..."
    
    # 创建临时目录
    mkdir -p /tmp/xray
    cd /tmp/xray
    
    # 下载最新版本
    log "下载Xray..."
    if ! wget --no-check-certificate -O xray.zip "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"; then
        handle_error "下载Xray失败"
        return 1
    fi
    
    # 解压
    log "解压文件..."
    if ! unzip -o xray.zip; then
        handle_error "解压失败"
        return 1
    fi
    
    # 移动文件
    log "安装Xray..."
    mv xray /usr/local/bin/
    chmod +x /usr/local/bin/xray
    
    # 创建配置目录
    mkdir -p /etc/xray
    mkdir -p /var/log/xray
    mkdir -p /etc/xray/track
    
    # 清理临时文件
    cd /
    rm -rf /tmp/xray
    
    log "Xray安装完成"
    return 0
}

# 环境配置模块
setup_environment() {
    log "开始环境配置..."
    
    # 设置防火墙规则
    log "设置防火墙规则..."
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT
    iptables -t nat -F
    iptables -t mangle -F
    iptables -F
    iptables -X
    iptables-save

    # 安装必要的软件包
    check_and_install_packages
    
    # 安装 Xray
    install_xray || return 1
    
    log "创建Xray服务文件..."
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

    log "启动Xray服务..."
    systemctl daemon-reload
    systemctl enable xray
    systemctl start xray
    
    log "环境配置完成"
    return 0
}

# 代理设置模块
set_socks5_credentials() {
    log "设置SOCKS5代理凭据..."
    
    read -p "请输入SOCKS5端口 [1-65535]: " socks_port
    while ! [[ "$socks_port" =~ ^[0-9]+$ ]] || [ "$socks_port" -lt 1 ] || [ "$socks_port" -gt 65535 ]; do
        log "无效的端口号，请重新输入"
        read -p "请输入SOCKS5端口 [1-65535]: " socks_port
    done
    
    read -p "请输入用户名: " socks_user
    while [ -z "$socks_user" ]; do
        log "用户名不能为空，请重新输入"
        read -p "请输入用户名: " socks_user
    done
    
    read -p "请输入密码: " socks_pass
    while [ -z "$socks_pass" ]; do
        log "密码不能为空，请重新输入"
        read -p "请输入密码: " socks_pass
    done
    
    configure_xray "$socks_port" "$socks_user" "$socks_pass"
    generate_proxy_list "$socks_port" "$socks_user" "$socks_pass"
    
    log "SOCKS5代理凭据设置完成"
    return 0
}

# 配置Xray
configure_xray() {
    local port=$1
    local user=$2
    local pass=$3
    
    log "配置Xray..."
    mkdir -p /etc/xray
    
    # 获取所有IP地址
    local ips=($(hostname -I))
    
    # 生成基础配置
    cat <<EOF > /etc/xray/serve.toml
{
    "log": {
        "loglevel": "info",
        "access": "/var/log/xray/access.log",
        "error": "/var/log/xray/error.log"
    },
EOF
    
    # 继续添加入站和出站配置...
    # 由于内容较长，我会在下一部分继续
        # 继续 configure_xray 函数
    # 添加入站配置
    cat <<EOF >> /etc/xray/serve.toml
    "inbounds": [
EOF

    local first=true
    for ip in "${ips[@]}"; do
        if [ "$first" = true ]; then
            first=false
        else
            echo "," >> /etc/xray/serve.toml
        fi
        
        cat <<EOF >> /etc/xray/serve.toml
        {
            "listen": "$ip",
            "port": $port,
            "protocol": "socks",
            "tag": "in_$ip",
            "settings": {
                "auth": "password",
                "udp": true,
                "accounts": [
                    {
                        "user": "$user",
                        "pass": "$pass"
                    }
                ]
            }
        }
EOF
    done

    # 添加出站配置
    cat <<EOF >> /etc/xray/serve.toml
    ],
    "outbounds": [
EOF

    first=true
    for ip in "${ips[@]}"; do
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
                "domainStrategy": "UseIP"
            },
            "sendThrough": "$ip"
        }
EOF
    done

    # 添加路由规则
    cat <<EOF >> /etc/xray/serve.toml
    ],
    "routing": {
        "rules": [
EOF

    first=true
    for ip in "${ips[@]}"; do
        if [ "$first" = true ]; then
            first=false
        else
            echo "," >> /etc/xray/serve.toml
        fi
        
        cat <<EOF >> /etc/xray/serve.toml
            {
                "type": "field",
                "inboundTag": ["in_$ip"],
                "outboundTag": "out_$ip"
            }
EOF
    done

    cat <<EOF >> /etc/xray/serve.toml
        ]
    }
}
EOF

    log "Xray配置已完成"
    
    # 验证配置
    if ! check_config; then
        return 1
    fi
    
    # 重启服务
    systemctl restart xray
    return 0
}

# 生成代理列表
generate_proxy_list() {
    local port=$1
    local user=$2
    local pass=$3
    
    log "生成代理列表文件..."
    local ips=($(hostname -I))
    
    echo -n "" > /root/proxy_list.txt
    for ip in "${ips[@]}"; do
        echo "$ip:$port:$user:$pass" >> /root/proxy_list.txt
    done
    
    log "代理列表文件已生成：/root/proxy_list.txt"
    return 0
}

# 清除代理规则
clear_proxy_rules() {
    log "清除所有代理规则..."
    
    # 停止服务
    if [ -f /etc/systemd/system/xray.service ]; then
        systemctl stop xray
        systemctl disable xray
        rm -f /etc/systemd/system/xray.service
    fi
    
    # 清除配置文件
    rm -f /etc/xray/serve.toml
    rm -rf /etc/xray/track
    
    # 清除防火墙规则
    iptables -F
    iptables -X
    iptables -t nat -F
    iptables -t mangle -F
    ip6tables -F
    ip6tables -X
    ip6tables -t nat -F
    ip6tables -t mangle -F
    
    # 保存防火墙规则
    iptables-save
    ip6tables-save
    
    # 删除代理列表
    rm -f /root/proxy_list.txt
    
    log "已清除所有代理规则"
    return 0
}
# 测试代理连通性
test_proxy_connectivity() {
    log "测试代理连通性..."
    
    if [ ! -f /root/proxy_list.txt ]; then
        handle_error "/root/proxy_list.txt 文件不存在"
        return 1
    }

    # 检查 xray 服务状态
    log "检查 Xray 服务状态..."
    if ! systemctl is-active --quiet xray; then
        handle_error "Xray 服务未运行"
        systemctl status xray
        return 1
    }

    while IFS= read -r line; do
        if [[ $line =~ ^(.+):([0-9]+):(.+):(.+)$ ]]; then
            local ip="${BASH_REMATCH[1]}"
            local port="${BASH_REMATCH[2]}"
            local user="${BASH_REMATCH[3]}"
            local pass="${BASH_REMATCH[4]}"
            
            log "测试代理: $ip:$port"
            log "使用凭据: $user:****"
            
            # 处理IPv6地址
            if [[ $ip =~ ":" ]]; then
                ip="[$ip]"
            fi

            # 测试连接
            log "尝试连接..."
            local curl_output
            if curl_output=$(curl -v --max-time 10 --socks5-hostname "$ip:$port" -U "$user:$pass" http://api.ipify.org 2>&1); then
                log "代理连接成功: $ip:$port"
                log "返回的IP: $curl_output"
            else
                log "代理连接失败: $ip:$port"
                log "错误详情:"
                log "$curl_output"
                
                # 诊断信息
                log "检查端口 $port 是否在监听..."
                if ss -tuln | grep -q ":$port "; then
                    log "端口 $port 正在监听"
                else
                    log "错误: 端口 $port 未在监听"
                fi
                
                log "检查防火墙规则..."
                iptables -L -n | grep "$port"
            fi
            
            log "----------------------------"
        else
            log "行格式不正确: $line"
        fi
    done < /root/proxy_list.txt

    # 显示 Xray 日志
    log "最近的 Xray 日志:"
    journalctl -u xray --no-pager -n 50
    
    return 0
}

# 带宽控制设置
setup_bandwidth_control() {
    log "设置带宽控制..."
    
    # 获取网络接口
    local interfaces=$(ip -o link show | awk -F': ' '{print $2}' | grep -v 'lo')
    log "检测到的网络接口: $interfaces"
    
    # 获取活动IP数量
    local active_ip_count=$(ss -H -t state established | awk '{print $5}' | cut -d: -f1 | sort | uniq | wc -l)
    log "当前活动的IP数量: $active_ip_count"

    # 获取总带宽设置
    read -p "请输入VPS的总带宽（例如50M）: " total_bandwidth
    if [[ ! $total_bandwidth =~ ^[0-9]+M$ ]]; then
        handle_error "带宽格式错误，请使用类似'50M'的格式"
        return 1
    fi

    if [ "$active_ip_count" -eq 0 ]; then
        log "没有活动的IP，跳过带宽设置"
        return 0
    fi

    # 计算每个IP的带宽
    local rate=$(echo "${total_bandwidth%M} / $active_ip_count" | bc)Mbit

    log "配置带宽控制..."
    for interface in $interfaces; do
        tc qdisc del dev $interface root 2>/dev/null || true
        tc qdisc add dev $interface root handle 1: htb default 30
        tc class add dev $interface parent 1: classid 1:1 htb rate $total_bandwidth

        for ip in $(hostname -I); do
            tc class add dev $interface parent 1:1 classid 1:10 htb rate ${rate} ceil ${rate}
            tc filter add dev $interface protocol ip parent 1:0 prio 1 u32 match ip dst $ip flowid 1:10
        done
    done

    log "带宽控制设置完成"
    return 0
}

# 启用BBR
enable_bbr() {
    log "启用BBR..."
    
    if ! sysctl net.ipv4.tcp_available_congestion_control | grep -q "bbr"; then
        handle_error "当前内核不支持BBR，请升级内核"
        return 1
    fi

    # 设置BBR
    echo "net.core.default_qdisc=fq" | sudo tee -a /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" | sudo tee -a /etc/sysctl.conf

    # 应用设置
    sudo sysctl -p

    # 验证
    if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        log "BBR已成功启用"
    else
        handle_error "BBR启用失败"
        return 1
    fi
    
    return 0
}

# 设置IP进出策略
set_ip_strategy() {
    log "配置IP进出策略..."
    
    # 获取IPv4和IPv6地址列表
    local ipv4_addrs=($(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1'))
    local ipv6_addrs=($(ip -6 addr show | grep -oP '(?<=inet6\s)[\da-f:]+' | grep -v '^fe80'))
    
    log "当前IPv4地址: ${ipv4_addrs[*]}"
    log "当前IPv6地址: ${ipv6_addrs[*]}"
    
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
            log "设置同IP进同IP出..."
            cat <<EOF > /etc/xray/serve.toml
{
    "log": {
        "loglevel": "info",
        "access": "/var/log/xray/access.log",
        "error": "/var/log/xray/error.log"
    },
    "inbounds": [
EOF
            # 添加所有IP的入站配置
            local first=true
            for ip in "${ipv4_addrs[@]}" "${ipv6_addrs[@]}"; do
                if [ "$first" = true ]; then
                    first=false
                else
                    echo "," >> /etc/xray/serve.toml
                fi
                cat <<EOF >> /etc/xray/serve.toml
        {
            "listen": "$ip",
            "port": $socks_port,
            "protocol": "socks",
            "tag": "in_$ip",
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
EOF
            done

            # 添加出站配置
            cat <<EOF >> /etc/xray/serve.toml
    ],
    "outbounds": [
EOF
            first=true
            for ip in "${ipv4_addrs[@]}" "${ipv6_addrs[@]}"; do
                if [ "$first" = true ]; then
                    first=false
                else
                    echo "," >> /etc/xray/serve.toml
                fi
                cat <<EOF >> /etc/xray/serve.toml
        {
            "protocol": "freedom",
            "tag": "out_$ip",
            "settings": {},
            "sendThrough": "$ip"
        }
EOF
            done

            # 添加路由规则
            cat <<EOF >> /etc/xray/serve.toml
    ],
    "routing": {
        "rules": [
EOF
            first=true
            for ip in "${ipv4_addrs[@]}" "${ipv6_addrs[@]}"; do
                if [ "$first" = true ]; then
                    first=false
                else
                    echo "," >> /etc/xray/serve.toml
                fi
                cat <<EOF >> /etc/xray/serve.toml
            {
                "type": "field",
                "inboundTag": ["in_$ip"],
                "outboundTag": "out_$ip"
            }
EOF
            done

            cat <<EOF >> /etc/xray/serve.toml
        ]
    }
}
EOF
            ;;
            
        2)
            log "设置IPv4进随机IPv4出..."
            # 创建IPv4状态跟踪文件
            cat <<EOF > /etc/xray/track/ipv4_state.json
{
    "last_used": "",
    "used_ips": []
}
EOF
            configure_random_strategy "ipv4" "${ipv4_addrs[*]}"
            ;;
            
        3)
            log "设置IPv4进随机IPv6出..."
            # 创建IPv6状态跟踪文件
            cat <<EOF > /etc/xray/track/ipv6_state.json
{
    "last_used": "",
    "used_ips": []
}
EOF
            configure_random_strategy "ipv6" "${ipv6_addrs[*]}"
            ;;
            
        *)
            handle_error "无效的选项"
            return 1
            ;;
    esac

    # 重启服务
    systemctl daemon-reload
    systemctl restart xray
    
    log "IP策略设置完成"
    log "检查 Xray 服务状态..."
    sleep 2
    systemctl status xray
    
    return 0
}

# 配置随机策略
configure_random_strategy() {
    local ip_type=$1
    local ip_list=($2)
    
    cat <<EOF > /etc/xray/serve.toml
{
    "log": {
        "loglevel": "info",
        "access": "/var/log/xray/access.log",
        "error": "/var/log/xray/error.log"
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

    local first=true
    for ip in "${ip_list[@]}"; do
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
                "domainStrategy": "Use${ip_type^}"
            },
            "sendThrough": "$ip"
        }
EOF
    done

    cat <<EOF >> /etc/xray/serve.toml
    ],
    "routing": {
        "balancers": [
            {
                "tag": "${ip_type}_balancer",
                "selector": [
EOF

    first=true
    for ip in "${ip_list[@]}"; do
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
                        "stateFile": "/etc/xray/track/${ip_type}_state.json",
                        "resetInterval": "0"
                    }
                }
            }
        ],
        "rules": [
            {
                "type": "field",
                "network": "tcp,udp",
                "balancerTag": "${ip_type}_balancer"
            }
        ]
    }
}
EOF
}

# 显示菜单
show_menu() {
    echo -e "\n=== Xray SOCKS5 代理服务器管理脚本 ==="
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
        5) test_proxy_connectivity ;;
        6) setup_bandwidth_control ;;
        7) enable_bbr ;;
        8) set_ip_strategy ;;
        9) log "退出脚本"; exit 0 ;;
        *) log "无效选项，请输入1-9之间的数字" ;;
    esac
}

# 主程序
main() {
    check_root
    detect_system
    check_and_install_packages
    
    while true; do
        show_menu
        echo -e "\n按回车键继续..."
        read
        clear
    done
}

# 启动主程序
main

