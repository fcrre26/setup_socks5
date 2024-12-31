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

check_and_install_iptables() {
    if ! command -v iptables &> /dev/null; then
        echo "未安装iptables，正在安装..."
        if [ "$ID" == "centos" ]; then
            sudo yum install iptables-services -y
            sudo systemctl enable iptables
        else
            sudo apt-get install iptables-persistent -y
        fi
    fi
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

    ip6tables -P INPUT ACCEPT
    ip6tables -P FORWARD ACCEPT
    ip6tables -P OUTPUT ACCEPT
    ip6tables -t nat -F
    ip6tables -t mangle -F
    ip6tables -F
    ip6tables -X

    iptables-save
    ip6tables-save

    install_xray
    echo "创建Xray服务文件..."
    cat <<EOF > /etc/systemd/system/xray.service
[Unit]
Description=The Xray Proxy Serve
After=network-online.target
[Service]
ExecStart=/usr/local/bin/xray -c /etc/xray/serve.toml
ExecStop=/bin/kill -s QUIT \$MAINPID
Restart=always
RestartSec=15s
[Install]
WantedBy=multi-user.target
EOF

    echo "启动Xray服务..."
    $service_manager daemon-reload
    $service_manager enable xray
    $service_manager start xray
    echo "环境配置完成。"
    return 0
}

install_xray() {
    echo "正在从GitHub下载Xray..."
    check_and_install_unzip
    wget --no-check-certificate -O /usr/local/bin/xray.zip "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"
    unzip /usr/local/bin/xray.zip -d /usr/local/bin
    rm /usr/local/bin/xray.zip
    chmod +x /usr/local/bin/xray
    echo "Xray已下载并设置为可执行。"
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
tag = "in$((i+1))"
settings = { auth = "password", udp = true, accounts = [{ user = "$2", pass = "$3" }] }
[[outbounds]]
protocol = "freedom"
tag = "out$((i+1))"

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

    while IFS= read -r line; do
        # 使用正则表达式解析行
        if [[ $line =~ ^(.+):([0-9]+):(.+):(.+)$ ]]; then
            ip="${BASH_REMATCH[1]}"
            port="${BASH_REMATCH[2]}"
            user="${BASH_REMATCH[3]}"
            pass="${BASH_REMATCH[4]}"
            
            echo "正在测试 $ip:$port..."
            
            # 检查是否为IPv6地址，并添加方括号
            if [[ $ip == *:* ]]; then
                ip="[$ip]"
            fi

            # 使用 curl 进行测试，并捕获详细的调试信息
            if curl -s -x socks5h://$user:$pass@$ip:$port http://httpbin.org/ip > /dev/null; then
                echo "$ip:$port 代理连接成功"
            else
                echo "$ip:$port 代理连接失败"
            fi
        else
            echo "行格式不正确: $line"
        fi
    done < /root/proxy_list.txt

    echo "代理连通性测试完成。"
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

    # 提示用户输入总带宽
    read -p "请输入VPS的总带宽（例如50M）: " total_bandwidth

    # 确保输入的带宽格式正确
    if [[ ! $total_bandwidth =~ ^[0-9]+M$ ]]; then
        echo "ERROR: 输入格式错误，请输入类似'50M'的格式。"
        return 1
    fi

    if [ "$active_ip_count" -eq 0 ]; then
        echo "INFO: 没有活动的IP，跳过带宽设置。"
        return 0
    fi

    # 动态计算每个IP的带宽
    local rate=$(echo "${total_bandwidth%M} / $active_ip_count" | bc)Mbit

    echo "INFO: 设置带宽控制..."
    for interface in $interfaces; do
        tc qdisc del dev $interface root 2>/dev/null  # 删除已有的qdisc配置
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
    
    # 检查当前内核是否支持BBR
    if ! sysctl net.ipv4.tcp_available_congestion_control | grep -q "bbr"; then
        echo "当前内核不支持BBR，请升级内核。"
        return 1
    fi

    # 设置BBR为默认拥塞控制算法
    echo "net.core.default_qdisc=fq" | sudo tee -a /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" | sudo tee -a /etc/sysctl.conf

    # 立即应用更改
    sudo sysctl -p

    # 验证BBR是否启用
    if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        echo "BBR已成功启用。"
    else
        echo "BBR启用失败，请检查配置。"
    fi
    return 0
}

# 随机选择未使用的IP地址
select_random_ip() {
    local available_ips=("$@")
    local selected_ip

    while [ ${#available_ips[@]} -gt 0 ]; do
        local index=$((RANDOM % ${#available_ips[@]}))
        selected_ip=${available_ips[$index]}
        if [[ ! " ${used_ips[@]} " =~ " ${selected_ip} " ]]; then
            used_ips+=("$selected_ip")
            echo "$selected_ip"
            return
        fi
        unset available_ips[$index]
        available_ips=("${available_ips[@]}")
    done

    echo "No available IPs left, reusing IPs."
    used_ips=()
    select_random_ip "$@"
}

# 设置IP进出策略
set_ip_strategy() {
    echo "请选择IP进出策略："
    echo "1. 同IP进同IP出"
    echo "2. 一个IP进，随机IPv4出"
    echo "3. 一个IPv4进，随机IPv6出"
    read -p "请输入选项 [1-3]: " strategy

    local ips=($(hostname -I))
    used_ips=()
    case $strategy in
        1)
            echo "设置同IP进同IP出..."
            for ip in "${ips[@]}"; do
                if [[ $ip == *:* ]]; then
                    ip6tables -t nat -A POSTROUTING -s $ip -j SNAT --to-source $ip
                    ip6tables -t nat -A PREROUTING -d $ip -j DNAT --to-destination $ip
                else
                    iptables -t nat -A POSTROUTING -s $ip -j SNAT --to-source $ip
                    iptables -t nat -A PREROUTING -d $ip -j DNAT --to-destination $ip
                fi
            done
            ;;
        2)
            echo "设置一个IP进，随机IPv4出..."
            for ip in "${ips[@]}"; do
                if [[ $ip != *:* ]]; then
                    random_ip=$(select_random_ip "${ips[@]}")
                    iptables -t nat -A POSTROUTING -s $ip -j SNAT --to-source $random_ip
                fi
            done
            ;;
        3)
            echo "设置一个IPv4进，随机IPv6出..."
            for ip in "${ips[@]}"; do
                if [[ $ip == *:* ]]; then
                    random_ip=$(select_random_ip "${ips[@]}")
                    ip6tables -t nat -A POSTROUTING -j SNAT --to-source $random_ip
                fi
            done
            ;;
        *)
            echo "无效选项，请输入1-3之间的数字"
            ;;
    esac

    iptables-save
    ip6tables-save
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
    sleep 60  # 每分钟检查和调整一次
done
