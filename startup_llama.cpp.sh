#!/bin/bash
set -e  # 遇到错误立即退出，保证脚本健壮性

# ====================== 第一步：定义核心变量（方便后续维护） ======================
echo -e "\033[34m【步骤1/10】初始化核心配置变量...\033[0m"
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
# 工作目录（llama.cpp_rerank的根目录）
LLAMA_ROOT_DIR="$PWD/llama.cpp_rerank"
# 启动脚本路径
START_SCRIPT_PATH="$PWD/start_llama.sh"
# systemd服务文件路径
SERVICE_FILE_PATH="/etc/systemd/system/llama-server.service"
# 模型文件完整路径
MODEL_FILE_PATH="$LLAMA_ROOT_DIR/qwen3-reranker-0.6b-q8_0.gguf"

# ====================== 第二步：检测CUDA环境 ======================
echo -e "\033[34m【步骤2/10】检测CUDA 13动态链接库...\033[0m"
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

# ====================== 第三步：创建工作目录 ======================
echo -e "\033[34m【步骤3/10】创建llama.cpp_rerank工作目录...\033[0m"
mkdir -p "$LLAMA_ROOT_DIR"
echo -e "\033[32m✅ 目录创建成功：$LLAMA_ROOT_DIR\033[0m"

# ====================== 第四步：下载预编译包（支持代理） ======================
echo -e "\033[34m【步骤4/10】尝试下载llama.cpp_rerank预编译包...\033[0m"

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

# 执行下载（先尝试原始地址）
download_llama_package "$LLAMA_DOWNLOAD_URL"

# ====================== 第五步：下载Qwen3-Reranker模型文件 ======================
echo -e "\033[34m【步骤5/10】下载Qwen3-Reranker模型文件...\033[0m"
wget -q --show-progress -O "$MODEL_FILE_PATH" "$MODEL_DOWNLOAD_URL"
if [ -f "$MODEL_FILE_PATH" ]; then
    echo -e "\033[32m✅ 模型文件下载完成：$MODEL_FILE_PATH\033[0m"
else
    echo -e "\033[31m❌ 模型文件下载失败，请检查网络或下载地址！\033[0m"
    exit 1
fi

# ====================== 第六步：创建start_llama.sh启动脚本（仅此处配置CUDA路径） ======================
echo -e "\033[34m【步骤6/10】创建启动脚本start_llama.sh（配置CUDA库路径）...\033[0m"
# 拼接llama-server的完整路径
LLAMA_SERVER_PATH="$LLAMA_ROOT_DIR/llama-server"

# 写入启动脚本内容（仅此处配置CUDA库路径，无临时环境变量）
cat > "$START_SCRIPT_PATH" << EOF
#!/bin/bash
# 仅在启动脚本中配置CUDA 13库路径（永久生效）
export LD_LIBRARY_PATH="$CUDA_LIB_DIR:\$LD_LIBRARY_PATH"
echo -e "\033[33m🔧 已配置CUDA库路径：LD_LIBRARY_PATH=\$LD_LIBRARY_PATH\033[0m"

# 测试llama-server可执行性
if ! "\$LLAMA_SERVER_PATH" -h > /dev/null 2>&1; then
    echo -e "\033[31m❌ llama-server执行失败，请检查CUDA库或预编译包！\033[0m"
    exit 1
fi
echo -e "\033[32m✅ llama-server可执行性测试通过！\033[0m"

# 启动llama-server
echo -e "\033[33m🚀 启动llama-server（重排序模式）...\033[0m"
"$LLAMA_SERVER_PATH" \
  --model "$MODEL_FILE_PATH" \
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
echo -e "\033[32m✅ 启动脚本创建完成：$START_SCRIPT_PATH\033[0m"

# ====================== 第七步：创建systemd开机自启服务 ======================
echo -e "\033[34m【步骤7/10】创建systemd服务文件...\033[0m"
cat > "$SERVICE_FILE_PATH" << EOF
[Unit]
Description=Llama Server for Rerank
After=network-online.target

[Service]
ExecStart=$START_SCRIPT_PATH
User=root
Group=root
Restart=always
RestartSec=3
# 服务中无需重复配置CUDA路径，启动脚本已包含

[Install]
WantedBy=multi-user.target
EOF

echo -e "\033[32m✅ systemd服务文件创建完成：$SERVICE_FILE_PATH\033[0m"

# ====================== 第八步：重新加载systemd并设置开机自启 ======================
echo -e "\033[34m【步骤8/10】配置开机自启并启动服务...\033[0m"
# 重新加载systemd配置
systemctl daemon-reload
# 设置开机自启
systemctl enable llama-server
# 启动服务
systemctl start llama-server

# 检查服务状态
if systemctl is-active --quiet llama-server; then
    echo -e "\033[32m✅ llama-server服务启动成功！\033[0m"
else
    echo -e "\033[31m❌ llama-server服务启动失败，请执行 systemctl status llama-server 查看详情！\033[0m"
fi

# ====================== 第九步：执行启动脚本（双重保障） ======================
echo -e "\033[34m【步骤9/10】执行启动脚本start_llama.sh...\033[0m"
# 后台执行启动脚本，避免阻塞终端
bash "$START_SCRIPT_PATH" &
echo -e "\033[32m🎉 所有操作完成！llama-server已启动，监听端口11435\033[0m"

# ====================== 第十步：输出常用命令 ======================
echo -e "\033[34m【步骤10/10】输出常用运维命令...\033[0m"
echo -e "\033[33m📌 常用命令：\033[0m"
echo -e "  - 查看服务状态：systemctl status llama-server"
echo -e "  - 重启服务：systemctl restart llama-server"
echo -e "  - 停止服务：systemctl stop llama-server"
echo -e "  - 手动启动：bash $START_SCRIPT_PATH"