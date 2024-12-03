#!/bin/bash

# 检测系统类型并设置相应的命令
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
                exit 1
                ;;
        esac
    else
        echo "无法识别的系统"
        exit 1
    fi
}

# 环境配置
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

    echo "下载并设置Xray..."
    wget -O /usr/local/bin/xray https://www.h1z1.xin/xray
    chmod +x /usr/local/bin/xray

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
}

# SOCKS5端口设置、用户名与密码设置
set_socks5_credentials() {
    read -p "请输入SOCKS5端口: " socks_port
    read -p "请输入用户名: " socks_user
    read -p "请输入密码: " socks_pass # 移除了 -s 选项，现在密码可见
    configure_xray "$socks_port" "$socks_user" "$socks_pass"
    generate_proxy_list "$socks_port" "$socks_user" "$socks_pass"
    echo "SOCKS5端口、用户名和密码设置完成。"
}

# 代理列表详情
show_proxy_details() {
    echo "代理列表详情："
    cat /root/proxy_list.txt
}

# 配置Xray
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
}

# 生成代理列表文件
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
}

# 菜单函数
show_menu() {
    echo "请选择要执行的操作："
    echo "1. 环境配置"
    echo "2. SOCKS5端口设置、用户名与密码设置"
    echo "3. 代理列表详情"
    echo "4. 退出"
    read -p "请输入选项 [1-4]: " option
    case $option in
        1) setup_environment ;;
        2) set_socks5_credentials ;;
        3) show_proxy_details ;;
        4) echo "退出脚本。"; exit ;;
        *) echo "无效选项，请输入1-4之间的数字" ;;
    esac
}

# 主程序
detect_system
while true; do
    show_menu
done
