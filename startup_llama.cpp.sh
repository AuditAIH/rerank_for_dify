#!/bin/bash
set -e  # 遇到错误立即退出，保证脚本健壮性

# ====================== 核心配置（恢复原路径，不修改为固定/opt） ======================
# CUDA 13官方默认动态链接库路径（64位系统）
CUDA13_LIB_PATH="/usr/local/cuda-13/lib64"
# ollama自带的CUDA 13动态链接库路径
OLLAMA_CUDA_PATH="/usr/local/lib/ollama/cuda_v13"
# 原始GitHub预编译包下载地址
LLAMA_DOWNLOAD_URL="https://github.com/AuditAIH/llama.cpp_rerank/releases/download/0.01/llama.cpp_rerank.tar.gz"
# GitHub代理前缀
GH_PROXY_PREFIX="https://gh-proxy.org/"
# 重排序模型下载地址
MODEL_DOWNLOAD_URL="https://www.modelscope.cn/models/ggml-org/Qwen3-Reranker-0.6B-Q8_0-GGUF/resolve/master/qwen3-reranker-0.6b-q8_0.gguf"
# 恢复你原有的工作目录（基于当前执行目录，不修改）
LLAMA_ROOT_DIR="$PWD/llama.cpp_rerank"
# 恢复你原有的启动脚本路径（基于当前执行目录）
START_SCRIPT_PATH="$PWD/start_llama.sh"
# systemd服务文件路径
SERVICE_FILE_PATH="/etc/systemd/system/llama-server.service"
# 模型文件完整路径
MODEL_FILE_PATH="$LLAMA_ROOT_DIR/qwen3-reranker-0.6b-q8_0.gguf"
# llama-server可执行文件路径
LLAMA_SERVER_PATH="$LLAMA_ROOT_DIR/llama-server"

# ====================== 第一步：检测CUDA环境 ======================
echo -e "\033[34m【步骤1/9】检测CUDA 13动态链接库...\033[0m"
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

# ====================== 第二步：创建工作目录 ======================
echo -e "\033[34m【步骤2/9】创建llama.cpp_rerank工作目录...\033[0m"
mkdir -p "$LLAMA_ROOT_DIR"
echo -e "\033[32m✅ 目录已就绪：$LLAMA_ROOT_DIR\033[0m"

# ====================== 第三步：下载预编译包（支持代理+重复执行兼容） ======================
echo -e "\033[34m【步骤3/9】检查并下载llama.cpp_rerank预编译包...\033[0m"

# 定义下载函数（带超时检测）
download_llama_package() {
    local download_url=$1
    # 使用wget下载，--timeout=10检测连接超时，--wait=1等待，--show-progress显示进度
    if ! wget --timeout=10 --wait=1 --show-progress -O - "$download_url" 2> /tmp/wget_error.log | tar -zxf - -C "$LLAMA_ROOT_DIR/"; then
        # 检查是否是连接超时（10秒未开始）
        if grep -E "Timeout|timed out" /tmp/wget_error.log > /dev/null; then
            echo -e "\033[31m❌ 连接GitHub超时（10秒未开始下载）！\033[0m"
            # 询问用户是否使用代理
            read -p "📌 是否使用gh-proxy.org代理下载？(yes/YES/Y/y 确认，其他取消)：" use_proxy
            if [[ "$use_proxy" =~ ^(yes|YES|Y|y)$ ]]; then
                echo -e "\033[33m🔧 切换到代理地址下载...\033[0m"
                local proxy_url="${GH_PROXY_PREFIX}${LLAMA_DOWNLOAD_URL}"
                # 重新使用代理地址下载
                wget --show-progress -O - "$proxy_url" | tar -zxf - -C "$LLAMA_ROOT_DIR/"
                echo -e "\033[32m✅ 代理下载预编译包完成！\033[0m"
                return 0
            else
                echo -e "\033[31m❌ 用户取消代理下载，脚本退出！\033[0m"
                rm -f /tmp/wget_error.log
                exit 1
            fi
        else
            # 其他错误（如文件不存在）
            echo -e "\033[31m❌ 下载失败！错误信息：\033[0m"
            cat /tmp/wget_error.log
            rm -f /tmp/wget_error.log
            exit 1
        fi
    else
        echo -e "\033[32m✅ 预编译包下载并解压完成！\033[0m"
        rm -f /tmp/wget_error.log
        return 0
    fi
}

# 检查预编译包是否已存在，避免重复下载
if [ -f "$LLAMA_SERVER_PATH" ]; then
    echo -e "\033[33mℹ️  预编译包已存在，跳过下载：$LLAMA_SERVER_PATH\033[0m"
else
    # 执行下载（先尝试原始地址）
    download_llama_package "$LLAMA_DOWNLOAD_URL"
fi

# ====================== 第四步：下载Qwen3-Reranker模型文件（重复执行兼容） ======================
echo -e "\033[34m【步骤4/9】检查并下载Qwen3-Reranker模型文件...\033[0m"
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

# ====================== 第五步：创建独立的启动脚本（全内置配置） ======================
echo -e "\033[34m【步骤5/9】创建/更新独立启动脚本...\033[0m"

# 写入启动脚本内容（所有配置全内置，无外部依赖）
cat > "$START_SCRIPT_PATH" << EOF
#!/bin/bash
set -e

# 内置固定配置（确保脚本完全独立）
CUDA_LIB_DIR="${CUDA_LIB_DIR}"
LLAMA_SERVER_PATH="${LLAMA_SERVER_PATH}"
MODEL_FILE_PATH="${MODEL_FILE_PATH}"

# 配置CUDA 13库路径（永久生效）
export LD_LIBRARY_PATH="\${CUDA_LIB_DIR}:\$LD_LIBRARY_PATH"
echo -e "\033[33m🔧 已配置CUDA库路径：LD_LIBRARY_PATH=\$LD_LIBRARY_PATH\033[0m"

# 测试llama-server可执行性
if ! "\${LLAMA_SERVER_PATH}" -h > /dev/null 2>&1; then
    echo -e "\033[31m❌ llama-server执行失败，请检查CUDA库或预编译包！\033[0m"
    exit 1
fi
echo -e "\033[32m✅ llama-server可执行性测试通过！\033[0m"

# 启动llama-server
echo -e "\033[33m🚀 启动llama-server（重排序模式）...\033[0m"
"\${LLAMA_SERVER_PATH}" \
  --model "\${MODEL_FILE_PATH}" \
  --host 0.0.0.0 \
  --port 11435 \
  --no-webui \
  --rerank \
  --ctx-size 8192 \
  --n-gpu-layers 99 \
  --verbose
EOF

# 添加可执行权限
chmod +x "$START_SCRIPT_PATH"
echo -e "\033[32m✅ 独立启动脚本已就绪：$START_SCRIPT_PATH\033[0m"

# ====================== 第六步：创建systemd开机自启服务 ======================
echo -e "\033[34m【步骤6/9】创建/更新systemd服务文件...\033[0m"
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
# 所有配置已内置在启动脚本中，无需额外配置

[Install]
WantedBy=multi-user.target
EOF

echo -e "\033[32m✅ systemd服务文件已就绪：$SERVICE_FILE_PATH\033[0m"

# ====================== 第七步：仅配置开机自启（不立即启动服务） ======================
echo -e "\033[34m【步骤7/9】配置开机自启（系统重启后自动启动）...\033[0m"
# 重新加载systemd配置
systemctl daemon-reload
# 仅设置开机自启，不执行start
systemctl enable llama-server > /dev/null 2>&1
echo -e "\033[32m✅ 已配置llama-server开机自启（系统重启后自动启动）\033[0m"

# ====================== 第八步：在当前会话直接启动服务 ======================
echo -e "\033[34m【步骤8/9】在当前会话启动llama-server...\033[0m"
echo -e "\033[33m🔧 执行启动脚本：$START_SCRIPT_PATH\033[0m"
# 直接在当前会话执行启动脚本（非后台，便于查看日志）
bash "$START_SCRIPT_PATH"

# ====================== 第九步：输出常用命令 ======================
echo -e "\033[34m【步骤9/9】输出常用运维命令...\033[0m"
echo -e "\033[33m📌 常用命令：\033[0m"
echo -e "  - 查看开机自启状态：systemctl is-enabled llama-server"
echo -e "  - 手动重启服务（后续）：systemctl restart llama-server"
echo -e "  - 手动停止服务（后续）：systemctl stop llama-server"
echo -e "  - 再次手动启动：${START_SCRIPT_PATH}"
echo -e "\033[32m🎉 操作完成！llama-server已在当前会话启动，监听端口11435\033[0m"
echo -e "\033[33mℹ️  系统重启后，llama-server会自动启动\033[0m"
