#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# ====================== 配置区（动态适配用户目录） ======================
OLLAMA_ROOT="/usr/local/lib/ollama"
LLAMA_SERVER_BIN="${OLLAMA_ROOT}/llama-server"

# 模型缓存路径 - modelscope默认存储路径（目录名中点号替换为下划线）
MODEL_DIR="${HOME}/.cache/modelscope/hub/models/ggml-org/Qwen3-Reranker-0___6B-Q8_0-GGUF"
MAIN_FILE="qwen3-reranker-0.6b-q8_0.gguf"
MODEL_ABS="${MODEL_DIR}/${MAIN_FILE}"

# 模型文件的 SHA256 哈希值（用于校验完整性）
EXPECTED_SHA256="22c9979ce4fbcdc5acdc310c6641c32797eff1aa980b8f7a2db8a8ea23429a48"

# 下载地址
URL_MAIN_MODEL="https://www.modelscope.cn/models/ggml-org/Qwen3-Reranker-0.6B-Q8_0-GGUF/resolve/master/${MAIN_FILE}"

# 服务固定参数
PORT=11435
HOST="0.0.0.0"
CTX_SIZE=8192
N_GPU_LAYERS=99
CUDA_DEV=0
START_SCRIPT_NAME="llama.cpp_qwen3_reranker_0.6b.sh"

# 获取当前脚本所在目录（启动脚本将创建在此处）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# ========================================================================

error_exit() {
    echo -e "\033[31m[ERROR] $1\033[0m" >&2
    exit 1
}
info_log() {
    echo -e "\033[32m[INFO] $1\033[0m"
}

# ========== 1. 检测GPU + 驱动版本，匹配固定CUDA后端 ==========
info_log "1. 检测NVIDIA GPU与驱动版本"
if ! command -v nvidia-smi &> /dev/null; then
    error_exit "未检测到NVIDIA显卡驱动，仅支持GPU模式，不支持CPU运行"
fi

DRIVER_MAJOR=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 | cut -d. -f1)
if [ -z "${DRIVER_MAJOR}" ]; then
    error_exit "无法读取NVIDIA驱动版本，请检查显卡驱动安装"
fi
info_log "NVIDIA驱动主版本：${DRIVER_MAJOR}"

# ========== 2. 检测Ollama程序，未安装则自动执行官方命令安装 ==========
info_log "2. 检测Ollama运行环境"
if [ ! -f "${LLAMA_SERVER_BIN}" ]; then
    info_log "未检测到Ollama，开始自动执行官方命令安装..."
    curl -fsSL https://ollama.com/install.sh | sh
    
    if [ ! -f "${LLAMA_SERVER_BIN}" ]; then
        error_exit "Ollama自动安装后仍未找到llama-server，请检查上方安装日志"
    fi
    info_log "Ollama安装完成"
fi
info_log "Ollama环境校验通过"

if [ "${DRIVER_MAJOR}" -ge 550 ] && [ -f "${OLLAMA_ROOT}/cuda_v13/libggml-cuda.so" ]; then
    CUDA_LIB_DIR="${OLLAMA_ROOT}/cuda_v13"
    info_log "驱动支持CUDA 13，匹配cuda_v13后端"
elif [ -f "${OLLAMA_ROOT}/cuda_v12/libggml-cuda.so" ]; then
    CUDA_LIB_DIR="${OLLAMA_ROOT}/cuda_v12"
    info_log "匹配cuda_v12后端"
else
    error_exit "Ollama目录无可用CUDA后端，请手动执行 curl -fsSL https://ollama.com/install.sh | sh 重装最新版"
fi

GGML_BACKEND_PATH="${CUDA_LIB_DIR}/libggml-cuda.so"
LD_LIB_PATH="${OLLAMA_ROOT}:${CUDA_LIB_DIR}"

# ========== 3. 模型目录初始化 ==========
info_log "3. 初始化模型缓存目录：${MODEL_DIR}"
mkdir -p "${MODEL_DIR}" || error_exit "创建模型目录失败"

# 下载函数：覆盖模式（先删除已有文件，不使用 -c 断点续传，避免文件损坏）
download_file() {
    local fname="$1" furl="$2"
    info_log "开始下载：${fname}"
    rm -f "${fname}"
    if ! wget --tries=3 --timeout=30 --progress=bar -O "${fname}" "${furl}"; then
        error_exit "下载失败: ${fname}"
    fi
    info_log "下载完成: ${fname}"
}

# ========== 4. 文件校验逻辑（SHA256 哈希校验） ==========
info_log "4. 校验模型文件（SHA256）"
NEED_DOWNLOAD=0

if [ -f "${MODEL_ABS}" ]; then
    info_log "模型文件已存在，开始校验SHA256哈希..."
    ACTUAL_SHA256=$(sha256sum "${MODEL_ABS}" | awk '{print $1}')
    info_log "期望哈希: ${EXPECTED_SHA256}"
    info_log "实际哈希: ${ACTUAL_SHA256}"
    
    if [ "${ACTUAL_SHA256}" = "${EXPECTED_SHA256}" ]; then
        info_log "✅ 哈希校验通过，模型文件完整，跳过下载"
    else
        info_log "❌ 哈希校验失败，文件可能损坏，需要重新下载"
        NEED_DOWNLOAD=1
    fi
else
    info_log "模型文件不存在，需要下载"
    NEED_DOWNLOAD=1
fi

# ========== 5. 下载缺失文件（覆盖模式） ==========
if [ "${NEED_DOWNLOAD}" -eq 1 ]; then
    cd "${MODEL_DIR}"
    download_file "${MAIN_FILE}" "${URL_MAIN_MODEL}"
    
    # 下载后再次校验
    ACTUAL_SHA256=$(sha256sum "${MODEL_ABS}" | awk '{print $1}')
    if [ "${ACTUAL_SHA256}" != "${EXPECTED_SHA256}" ]; then
        error_exit "下载后哈希校验失败！期望: ${EXPECTED_SHA256}, 实际: ${ACTUAL_SHA256}"
    fi
    info_log "✅ 下载完成且哈希校验通过"
fi

# ========== 6. 生成纯硬编码启动脚本（在当前脚本目录） ==========
info_log "5. 生成启动脚本：${SCRIPT_DIR}/${START_SCRIPT_NAME}"
cat > "${SCRIPT_DIR}/${START_SCRIPT_NAME}" <<EOF
#!/bin/bash
# Qwen3-Reranker-0.6B 服务启动脚本
# 自动生成，已匹配当前系统驱动与CUDA后端
# 服务监听：${HOST}:${PORT}

export GGML_BACKEND_PATH="${GGML_BACKEND_PATH}"
export LD_LIBRARY_PATH="${LD_LIB_PATH}"
export CUDA_VISIBLE_DEVICES=${CUDA_DEV}

${LLAMA_SERVER_BIN} \\
    --model ${MODEL_ABS} \\
    --host ${HOST} \\
    --port ${PORT} \\
    --no-webui \\
    --rerank \\
    --ctx-size ${CTX_SIZE} \\
    --n-gpu-layers ${N_GPU_LAYERS}
EOF

chmod +x "${SCRIPT_DIR}/${START_SCRIPT_NAME}"

info_log "========================================"
info_log "所有前置校验完成，自动启动服务"
info_log "启动脚本路径：${SCRIPT_DIR}/${START_SCRIPT_NAME}"
info_log "模型文件路径：${MODEL_ABS}"
info_log "服务地址：http://${HOST}:${PORT}"
info_log "========================================"

# ========== 7. 直接执行启动脚本 ==========
bash "${SCRIPT_DIR}/${START_SCRIPT_NAME}"
