#!/bin/bash
set -e  # 遇到错误立即退出，保证脚本健壮性

# ====================== 第一步：解析命令行参数 ======================
# 初始化参数标志
use_proxy_flag=false  # 是否强制使用代理
use_cpu_flag=false    # 是否下载CPU版本

# 解析参数
for arg in "$@"; do
    case $arg in
        --proxy)
        use_proxy_flag=true
        shift # 移除已解析的参数
        ;;
        --cpu)
        use_cpu_flag=true
        shift # 移除已解析的参数
        ;;
        *)
        # 未知参数提示
        echo -e "\033[31m❌ 未知参数：$arg\033[0m"
        echo -e "\033[33m支持的参数：--proxy（强制使用代理下载）、--cpu（下载CPU版本llama.cpp）\033[0m"
        exit 1
        ;;
    esac
done

# ====================== 核心配置（保留你的原始路径） ======================
# CUDA 13官方默认动态链接库路径（64位系统）
CUDA13_LIB_PATH="/usr/local/cuda-13/lib64"
# ollama自带的CUDA 13动态链接库路径
OLLAMA_CUDA_PATH="/usr/local/lib/ollama/cuda_v13"
# GitHub代理前缀
GH_PROXY_PREFIX="https://gh-proxy.org/"
# 重排序模型下载地址
MODEL_DOWNLOAD_URL="https://www.modelscope.cn/models/ggml-org/Qwen3-Reranker-0.6B-Q8_0-GGUF/resolve/master/qwen3-reranker-0.6b-q8_0.gguf"
# 保留你原有的工作目录（基于当前执行目录）
LLAMA_ROOT_DIR="$PWD/llama.cpp_rerank"
# 保留你原有的启动脚本路径
START_SCRIPT_PATH="$PWD/start_llama.sh"
# systemd服务文件路径
SERVICE_FILE_PATH="/etc/systemd/system/llama-server.service"
# 模型文件完整路径
MODEL_FILE_PATH="$LLAMA_ROOT_DIR/qwen3-reranker-0.6b-q8_0.gguf"

# 根据--cpu参数选择下载地址
if [ "$use_cpu_flag" = true ]; then
    # CPU版本下载地址
    LLAMA_DOWNLOAD_URL="https://github.com/ggml-org/llama.cpp/releases/download/b7524/llama-b7524-bin-ubuntu-x64.tar.gz"
    echo -e "\033[33m🔧 检测到--cpu参数，将下载CPU版本llama.cpp：$LLAMA_DOWNLOAD_URL\033[0m"
else
    # 原始GPU版本下载地址
    LLAMA_DOWNLOAD_URL="https://github.com/AuditAIH/llama.cpp_rerank/releases/download/0.01/llama.cpp_rerank.tar.gz"
fi
# 基础可执行文件路径（后续会验证/修正）
LLAMA_SERVER_PATH="$LLAMA_ROOT_DIR/llama-server"

# ====================== 第二步：检测CUDA环境（仅非CPU模式需要） ======================
if [ "$use_cpu_flag" = false ]; then
    echo -e "\033[34m【步骤1/10】检测CUDA 13动态链接库...\033[0m"
    # 初始化CUDA库路径变量
    CUDA_LIB_DIR=""

    # 1. 检测官方CUDA 13
    if [ -d "$CUDA13_LIB_PATH" ]; then
        echo -e "\033[32m✅ 检测到官方CUDA 13库：$CUDA13_LIB_PATH\033[0m"
        CUDA_LIB_DIR="$CUDA13_LIB_PATH"
    # 2. 检测ollama自带的CUDA 13
    elif [ -d "$OLLAMA_CUDA_PATH" ]; then
        echo -e "\033[32m✅ 检测到ollama自带的CUDA 13库：$OLLAMA_CUDA_PATH\033[0m"
        CUDA_LIB_DIR="$OLLAMA_CUDA_PATH"
    # 3. 两者都不存在，提示下载
    else
        echo -e "\033[31m❌ 未检测到CUDA 13或ollama自带的CUDA 13库！\033[0m"
        echo -e "\033[33m请前往NVIDIA官网下载CUDA 13：https://developer.nvidia.com/cuda-13-0-0-download-archive\033[0m"
        exit 1  # 退出脚本，避免后续无效操作
    fi
else
    # CPU模式跳过CUDA检测
    echo -e "\033[34m【步骤1/10】CPU模式，跳过CUDA环境检测...\033[0m"
    CUDA_LIB_DIR=""  # CPU模式无需CUDA路径
fi

# ====================== 第三步：创建工作目录 ======================
echo -e "\033[34m【步骤2/10】创建llama.cpp_rerank工作目录...\033[0m"
mkdir -p "$LLAMA_ROOT_DIR"
echo -e "\033[32m✅ 目录已就绪：$LLAMA_ROOT_DIR\033[0m"

# ====================== 第四步：下载预编译包（支持--proxy参数，跳过检测） ======================
echo -e "\033[34m【步骤3/10】下载llama.cpp预编译包...\033[0m"

# 定义下载函数（支持强制代理）
download_llama_package() {
    local base_url=$1
    local final_url=""

    # 如果指定--proxy，直接使用代理地址
    if [ "$use_proxy_flag" = true ]; then
        final_url="${GH_PROXY_PREFIX}${base_url}"
        echo -e "\033[33m🔧 检测到--proxy参数，强制使用代理下载：$final_url\033[0m"
    else
        final_url=$base_url
        echo -e "\033[33m🔧 使用原始地址下载：$final_url\033[0m"
    fi

    # 执行下载（--proxy模式跳过超时检测，直接下载）
    if ! wget --show-progress -O - "$final_url" 2> /tmp/wget_error.log | tar -zxf - -C "$LLAMA_ROOT_DIR/"; then
        echo -e "\033[31m❌ 下载失败！错误信息：\033[0m"
        cat /tmp/wget_error.log
        rm -f /tmp/wget_error.log
        exit 1
    else
        echo -e "\033[32m✅ 预编译包下载并解压完成！\033[0m"
        rm -f /tmp/wget_error.log
        
        # ====================== 关键修复：处理解压后多余的目录层级 ======================
        echo -e "\033[34m【步骤4/10】检查并扁平化解压目录...\033[0m"
        # 查找LLAMA_ROOT_DIR下的一级子目录（如llama-b7524）
        sub_dirs=("$LLAMA_ROOT_DIR"/*/)
        for sub_dir in "${sub_dirs[@]}"; do
            # 仅处理实际存在的目录（排除通配符本身）
            if [ -d "$sub_dir" ]; then
                echo -e "\033[33m🔧 检测到多余子目录：$sub_dir，开始扁平化处理...\033[0m"
                # 将子目录中的所有文件/文件夹移动到LLAMA_ROOT_DIR
                mv "$sub_dir"* "$LLAMA_ROOT_DIR/"
                # 删除空的子目录
                rm -rf "$sub_dir"
                echo -e "\033[32m✅ 已将子目录内容移动到主目录，删除空目录：$sub_dir\033[0m"
            fi
        done
        return 0
    fi
}

# 检查预编译包是否已存在，避免重复下载
if [ -f "$LLAMA_SERVER_PATH" ]; then
    echo -e "\033[33mℹ️  预编译包已存在，跳过下载：$LLAMA_SERVER_PATH\033[0m"
else
    # 执行下载（根据参数自动选择地址/代理）
    download_llama_package "$LLAMA_DOWNLOAD_URL"
    
    # 二次验证：确保llama-server存在（防止扁平化后仍找不到）
    if [ ! -f "$LLAMA_SERVER_PATH" ]; then
        echo -e "\033[31m❌ 解压后未找到llama-server，检查下载包是否完整！\033[0m"
        exit 1
    fi
fi

# ====================== 第五步：下载Qwen3-Reranker模型文件 ======================
echo -e "\033[34m【步骤5/10】检查并下载Qwen3-Reranker模型文件...\033[0m"
if [ -f "$MODEL_FILE_PATH" ]; then
    echo -e "\033[33mℹ️  模型文件已存在，跳过下载：$MODEL_FILE_PATH\033[0m"
else
    wget -q --show-progress -O "$MODEL_FILE_PATH" "$MODEL_DOWNLOAD_URL"
    if [ -f "$MODEL_FILE_PATH" ]; then
        echo -e "\033[32m✅ 模型文件下载完成：$MODEL_FILE_PATH\033[0m"
    else
        echo -e "\033[31m❌ 模型文件下载失败，请检查网络或下载地址！\033[0m"
        exit 1
    fi
fi

# ====================== 第六步：创建独立的启动脚本 ======================
echo -e "\033[34m【步骤6/10】创建/更新独立启动脚本...\033[0m"

# 写入启动脚本内容（适配CPU/GPU模式）
cat > "$START_SCRIPT_PATH" << EOF
#!/bin/bash
set -e

# 内置配置（适配CPU/GPU模式）
CUDA_LIB_DIR="${CUDA_LIB_DIR}"
LLAMA_SERVER_PATH="${LLAMA_SERVER_PATH}"
MODEL_FILE_PATH="${MODEL_FILE_PATH}"
USE_CPU_MODE=${use_cpu_flag}

# GPU模式配置CUDA路径，CPU模式跳过
if [ "\$USE_CPU_MODE" = false ]; then
    export LD_LIBRARY_PATH="\${CUDA_LIB_DIR}:\$LD_LIBRARY_PATH"
    echo -e "\033[33m🔧 已配置CUDA库路径：LD_LIBRARY_PATH=\$LD_LIBRARY_PATH\033[0m"
else
    echo -e "\033[33m🔧 CPU模式，无需配置CUDA库路径\033[0m"
fi

# 测试llama-server可执行性
if ! "\${LLAMA_SERVER_PATH}" -h > /dev/null 2>&1; then
    echo -e "\033[31m❌ llama-server执行失败，请检查预编译包！\033[0m"
    exit 1
fi
echo -e "\033[32m✅ llama-server可执行性测试通过！\033[0m"

# 启动llama-server
echo -e "\033[33m🚀 启动llama-server（重排序模式）...\033[0m"
"\${LLAMA_SERVER_PATH}" \
  --model "\${MODEL_FILE_PATH}" \
  --host 0.0.0.0 \
  --port 11437 \
  --no-webui \
  --rerank \
  --ctx-size 8192 \
  --verbose
EOF

# 添加可执行权限
chmod +x "$START_SCRIPT_PATH"
echo -e "\033[32m✅ 独立启动脚本已就绪：$START_SCRIPT_PATH\033[0m"

# ====================== 第七步：创建systemd开机自启服务 ======================
echo -e "\033[34m【步骤7/10】创建/更新systemd服务文件...\033[0m"
cat > "$SERVICE_FILE_PATH" << EOF
[Unit]
Description=Llama Server for Rerank
After=network-online.target

[Service]
ExecStart=${START_SCRIPT_PATH}
User=root
Group=root
Restart=always
RestartSec=3
# 适配CPU/GPU模式，配置内置在启动脚本中

[Install]
WantedBy=multi-user.target
EOF

echo -e "\033[32m✅ systemd服务文件已就绪：$SERVICE_FILE_PATH\033[0m"

# ====================== 第八步：仅配置开机自启（不立即启动服务） ======================
echo -e "\033[34m【步骤8/10】配置开机自启（系统重启后自动启动）...\033[0m"
# 重新加载systemd配置
systemctl daemon-reload
# 仅设置开机自启，不执行start
systemctl enable llama-server > /dev/null 2>&1
echo -e "\033[32m✅ 已配置llama-server开机自启（系统重启后自动启动）\033[0m"

# ====================== 第九步：在当前会话直接启动服务 ======================
echo -e "\033[34m【步骤9/10】在当前会话启动llama-server...\033[0m"
echo -e "\033[33m🔧 执行启动脚本：$START_SCRIPT_PATH\033[0m"
# 直接在当前会话执行启动脚本（非后台，便于查看日志）
bash "$START_SCRIPT_PATH"

# ====================== 第十步：输出常用命令 ======================
echo -e "\033[34m【步骤10/10】输出常用运维命令...\033[0m"
echo -e "\033[33m📌 常用命令：\033[0m"
echo -e "  - 查看开机自启状态：systemctl is-enabled llama-server"
echo -e "  - 手动重启服务（后续）：systemctl restart llama-server"
echo -e "  - 手动停止服务（后续）：systemctl stop llama-server"
echo -e "  - 再次手动启动：${START_SCRIPT_PATH}"
echo -e "\033[32m🎉 操作完成！llama-server已在当前会话启动，监听端口11435\033[0m"
echo -e "\033[33mℹ️  系统重启后，llama-server会自动启动\033[0m"
