#!/bin/bash

# 检查是否以root权限运行
if [ "$EUID" -ne 0 ]; then 
    echo "请使用root权限运行此脚本"
    exit 1
fi

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 生成随机十六进制数
generate_random_hex() {
    local length=$1
    head -c $((length/2)) /dev/urandom | hexdump -ve '1/1 "%.2x"'
}

# 获取主网卡名称
get_main_interface() {
    MAIN_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
    if [ -z "$MAIN_INTERFACE" ]; then
        echo -e "${RED}错误: 无法检测到主网卡${NC}"
        exit 1
    fi
    echo $MAIN_INTERFACE
}

# 获取IPv6前缀
get_ipv6_prefix() {
    local interface=$1
    IPV6_PREFIX=$(ip -6 addr show dev $interface | grep -v fe80 | grep -v fd00 | grep inet6 | head -n1 | awk '{print $2}' | cut -d'/' -f1 | sed 's/:[^:]*$/::/')
    if [ -z "$IPV6_PREFIX" ]; then
        echo -e "${RED}错误: 未检测到IPv6地址${NC}"
        echo -e "${YELLOW}可能的原因:${NC}"
        echo "1. 系统未启用IPv6"
        echo "2. 网络接口没有配置IPv6"
        echo "3. VPS可能不支持IPv6"
        echo -e "\n${YELLOW}建议操作:${NC}"
        echo "1. 检查系统IPv6状态: sysctl net.ipv6.conf.all.disable_ipv6"
        echo "2. 检查网络接口状态: ip a"
        echo "3. 联系VPS提供商确认IPv6支持"
        return 1
    fi
    echo $IPV6_PREFIX
}

# 添加IPv6地址
add_ipv6_addresses() {
    local interface=$1
    local prefix=$2
    local num=$3
    
    # 创建配置文件目录
    mkdir -p /etc/network/interfaces.d/
    
    # 创建或追加配置文件
    CONFIG_FILE="/etc/network/interfaces.d/60-ipv6-addresses"
    
    # 如果是新建，添加头部注释
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "# 自动生成的IPv6配置" > $CONFIG_FILE
    fi
    
    # 用于存储已生成的地址
    declare -A GENERATED_ADDRESSES
    
    # 生成并添加IPv6地址
    count=0
    while [ $count -lt $num ]; do
        RANDOM_SUFFIX=$(generate_random_hex 16)
        NEW_IPV6="${prefix}${RANDOM_SUFFIX}"
        
        if [ -z "${GENERATED_ADDRESSES[$NEW_IPV6]}" ]; then
            GENERATED_ADDRESSES[$NEW_IPV6]=1
            
            echo "" >> $CONFIG_FILE
            echo "iface $interface inet6 static" >> $CONFIG_FILE
            echo "    address $NEW_IPV6" >> $CONFIG_FILE
            echo "    netmask 64" >> $CONFIG_FILE
            
            # 立即添加IPv6地址
            ip -6 addr add $NEW_IPV6/64 dev $interface 2>/dev/null
            
            echo -e "${GREEN}已添加IPv6地址: $NEW_IPV6${NC}"
            ((count++))
        fi
    done
    
    # 确保interfaces文件包含配置
    if ! grep -q "source /etc/network/interfaces.d/*" /etc/network/interfaces; then
        echo "source /etc/network/interfaces.d/*" >> /etc/network/interfaces
    fi
}

# 删除所有配置的IPv6地址
delete_all_ipv6() {
    local interface=$1
    
    # 删除配置文件
    CONFIG_FILE="/etc/network/interfaces.d/60-ipv6-addresses"
    if [ -f "$CONFIG_FILE" ]; then
        rm -f "$CONFIG_FILE"
        echo -e "${GREEN}已删除配置文件${NC}"
    fi
    
    # 删除所有非本地IPv6地址
    for addr in $(ip -6 addr show dev $interface | grep "inet6" | grep -v "fe80" | awk '{print $2}'); do
        ip -6 addr del $addr dev $interface
        echo -e "${YELLOW}已删除IPv6地址: $addr${NC}"
    done
    
    echo -e "${GREEN}所有配置的IPv6地址已删除${NC}"
}

# 显示当前IPv6地址
show_current_ipv6() {
    local interface=$1
    echo -e "${YELLOW}当前IPv6地址列表：${NC}"
    local ipv6_list=$(ip -6 addr show dev $interface | grep "inet6" | grep -v "fe80")
    if [ -z "$ipv6_list" ]; then
        echo -e "${RED}未检测到任何IPv6地址${NC}"
        return 1
    fi
    echo "$ipv6_list"
}

# 创建测试脚本
create_test_script() {
    TEST_SCRIPT="/usr/local/bin/test-ipv6.sh"
    cat > $TEST_SCRIPT << 'EOF'
#!/bin/bash
INTERFACE=$1
if [ -z "$INTERFACE" ]; then
    echo "请指定网络接口"
    exit 1
fi

# 检查是否有IPv6地址
IPV6_ADDRS=$(ip -6 addr show dev $INTERFACE | grep "inet6" | grep -v "fe80" | awk '{print $2}' | cut -d'/' -f1)
if [ -z "$IPV6_ADDRS" ]; then
    echo "错误: 该接口没有配置IPv6地址"
    exit 1
fi

echo "开始测试所有IPv6地址..."
for addr in $IPV6_ADDRS; do
    echo "测试地址: $addr"
    if ping6 -c 1 -I $addr ipv6.google.com >/dev/null 2>&1; then
        echo -e "\033[0;32m✓ 连接成功\033[0m"
    else
        echo -e "\033[0;31m✗ 连接失败\033[0m"
    fi
    echo "-------------------"
done
EOF
    chmod +x $TEST_SCRIPT
}

# 检查IPv6是否启用
check_ipv6() {
    if [ "$(sysctl -n net.ipv6.conf.all.disable_ipv6)" -eq 1 ]; then
        echo -e "${RED}IPv6 当前被禁用${NC}"
        echo -e "${YELLOW}是否要启用IPv6？(y/n)${NC}"
        read -r enable_ipv6
        if [ "$enable_ipv6" = "y" ]; then
            echo "net.ipv6.conf.all.disable_ipv6 = 0" >> /etc/sysctl.conf
            echo "net.ipv6.conf.default.disable_ipv6 = 0" >> /etc/sysctl.conf
            sysctl -p
            echo -e "${GREEN}IPv6已启用，请重新运行脚本${NC}"
            exit 0
        fi
    fi
}

# 主菜单
show_menu() {
    echo -e "${YELLOW}IPv6地址管理工具${NC}"
    echo "1. 添加随机IPv6地址"
    echo "2. 删除所有IPv6地址"
    echo "3. 显示当前IPv6地址"
    echo "4. 测试IPv6连通性"
    echo "0. 退出"
    echo -e "${YELLOW}请选择操作 [0-4]:${NC}"
}

# 主程序
main() {
    # 检查IPv6状态
    check_ipv6
    
    # 获取网络接口和IPv6前缀
    INTERFACE=$(get_main_interface)
    PREFIX=$(get_ipv6_prefix $INTERFACE)
    if [ $? -ne 0 ]; then
        echo -e "${RED}是否仍要继续？(y/n):${NC}"
        read -r continue_anyway
        if [ "$continue_anyway" != "y" ]; then
            exit 1
        fi
    fi
    
    create_test_script
    
    while true; do
        clear  # 清屏
        show_menu
        read -r choice
        
        case $choice in
            1)
                echo -e "${YELLOW}当前网卡: $INTERFACE${NC}"
                if [ ! -z "$PREFIX" ]; then
                    echo -e "${YELLOW}IPv6前缀: $PREFIX${NC}"
                else
                    echo -e "${RED}警告: 未检测到IPv6前缀${NC}"
                    echo -e "是否手动输入IPv6前缀？(y/n): "
                    read -r manual_prefix
                    if [ "$manual_prefix" = "y" ]; then
                        read -p "请输入IPv6前缀(格式如 2001:db8::): " PREFIX
                    else
                        continue
                    fi
                fi
                read -p "请输入要添加的IPv6地址数量: " num_addresses
                if [[ "$num_addresses" =~ ^[0-9]+$ ]]; then
                    add_ipv6_addresses $INTERFACE $PREFIX $num_addresses
                else
                    echo -e "${RED}请输入有效的数字${NC}"
                fi
                ;;
            2)
                echo -e "${RED}警告：这将删除所有配置的IPv6地址${NC}"
                read -p "是否继续？(y/n): " confirm
                if [ "$confirm" = "y" ]; then
                    delete_all_ipv6 $INTERFACE
                fi
                ;;
            3)
                show_current_ipv6 $INTERFACE
                ;;
            4)
                if ! show_current_ipv6 $INTERFACE >/dev/null 2>&1; then
                    echo -e "${RED}错误: 没有可测试的IPv6地址${NC}"
                else
                    echo "开始测试IPv6连通性..."
                    /usr/local/bin/test-ipv6.sh $INTERFACE
                fi
                ;;
            0)
                echo "退出程序"
                exit 0
                ;;
            *)
                echo -e "${RED}无效的选择${NC}"
                ;;
        esac
        
        echo -e "\n按回车键继续..."
        read
    done
}

# 运行主程序
main
