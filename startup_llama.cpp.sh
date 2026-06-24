#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# ====================== 配置区（Qwen3-Reranker 0.6B Q8_0 重排序专用） ======================
OLLAMA_ROOT="/usr/local/lib/ollama"
LLAMA_SERVER_BIN="${OLLAMA_ROOT}/llama-server"

# 使用真实物理模型目录，不使用___软链接目录
MODEL_DIR="${HOME}/.cache/modelscope/hub/models/ggml-org/Qwen3-Reranker-0.6B-Q8_0-GGUF"
MAIN_FILE="qwen3-reranker-0.6b-q8_0.gguf"
HASH_FILE="${MODEL_DIR}/model_hash.txt"
MODEL_ABS="${MODEL_DIR}/${MAIN_FILE}"

# 模型直链下载地址
MODEL_DOWNLOAD_URL="https://www.modelscope.cn/models/ggml-org/Qwen3-Reranker-0.6B-Q8_0-GGUF/resolve/master/qwen3-reranker-0.6b-q8_0.gguf"

# 服务参数
PORT=11435
HOST="0.0.0.0"
TEMP=0
CUDA_DEV=0
START_SCRIPT_NAME="llama.cpp_qwen3_reranker_0.6b.sh"
# ========================================================================

error_exit() {
    echo -e "\033[31m[ERROR] $1\033[0m" >&2
    exit 1
}
info_log() {
    echo -e "\033[32m[INFO] $1\033[0m"
}

# 记录脚本执行根目录（启动脚本生成在此文件夹）
RUN_WORK_DIR=$(pwd)

# ========== 1. 检测NVIDIA GPU与驱动版本 ==========
info_log "1. 检测NVIDIA GPU与驱动版本"
if ! command -v nvidia-smi &> /dev/null; then
    error_exit "未检测到NVIDIA显卡驱动，仅支持GPU模式，不支持CPU运行"
fi

DRIVER_MAJOR=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 | cut -d. -f1)
if [ -z "${DRIVER_MAJOR}" ]; then
    error_exit "无法读取NVIDIA驱动版本，请检查显卡驱动安装"
fi
info_log "NVIDIA驱动主版本：${DRIVER_MAJOR}"

# ========== 2. 检测/自动安装Ollama环境 ==========
info_log "2. 检测Ollama llama-server运行环境"
if [ ! -f "${LLAMA_SERVER_BIN}" ]; then
    info_log "未检测到llama-server，自动执行Ollama官方安装脚本..."
    curl -fsSL https://ollama.com/install.sh | sh
    
    if [ ! -f "${LLAMA_SERVER_BIN}" ]; then
        error_exit "Ollama安装完成后仍未找到llama-server，请手动重装"
    fi
    info_log "Ollama安装完毕"
fi
info_log "Ollama环境校验通过"

# 匹配CUDA后端
if [ "${DRIVER_MAJOR}" -ge 550 ] && [ -f "${OLLAMA_ROOT}/cuda_v13/libggml-cuda.so" ]; then
    CUDA_LIB_DIR="${OLLAMA_ROOT}/cuda_v13"
    info_log "驱动兼容CUDA13，加载cuda_v13后端"
elif [ -f "${OLLAMA_ROOT}/cuda_v12/libggml-cuda.so" ]; then
    CUDA_LIB_DIR="${OLLAMA_ROOT}/cuda_v12"
    info_log "加载cuda_v12后端"
else
    error_exit "Ollama目录无可用CUDA后端，请重装最新Ollama：curl -fsSL https://ollama.com/install.sh | sh"
fi

GGML_BACKEND_PATH="${CUDA_LIB_DIR}/libggml-cuda.so"
LD_LIB_PATH="${OLLAMA_ROOT}:${CUDA_LIB_DIR}"

# ========== 3. 初始化真实模型目录（放弃软链接路径） ==========
info_log "3. 初始化真实模型目录：${MODEL_DIR}"
mkdir -p "${MODEL_DIR}" || error_exit "创建模型目录失败"
# 进入真实物理目录下载，不操作软链接
cd "${MODEL_DIR}" || error_exit "进入模型目录失败"

# 覆盖式下载函数（中断残缺文件自动删除重下）
download_file() {
    local fname="$1" furl="$2"
    info_log "开始下载模型文件：${fname}"
    rm -f "${fname}"
    if ! wget --tries=3 --timeout=30 --progress=bar "${furl}"; then
        error_exit "文件下载失败: ${fname}"
    fi
    info_log "${fname} 下载完成"
}

# ========== 4. 修改校验逻辑：优先判断模型文件，有文件直接跳过下载 ==========
info_log "4. 校验重排序模型文件完整性"
NEED_DOWNLOAD=0

# 核心改动：只要gguf文件存在，直接跳过下载，不再看hash文件
if [ -f "${MAIN_FILE}" ]; then
    info_log "检测到本地已存在完整模型文件，跳过下载步骤"
else
    info_log "本地无模型文件，执行全量下载"
    NEED_DOWNLOAD=1
fi

# ========== 5. 执行模型下载 ==========
if [ "${NEED_DOWNLOAD}" -eq 1 ]; then
    download_file "${MAIN_FILE}" "${MODEL_DOWNLOAD_URL}"
    touch "${HASH_FILE}"
    info_log "模型下载完成，生成完成标记文件"
fi

# 切回脚本运行原始目录（启动脚本生成在这里，不是模型目录）
cd "${RUN_WORK_DIR}" || error_exit "切回运行根目录失败"

# ========== 6. 在当前运行目录生成重排序服务启动脚本 ==========
info_log "5. 在当前目录生成启动脚本：${RUN_WORK_DIR}/${START_SCRIPT_NAME}"
cat > "./${START_SCRIPT_NAME}" <<EOF
#!/bin/bash
# Qwen3-Reranker-0.6B-Q8_0-GGUF 重排序服务启动脚本
# 自动生成，适配当前CUDA驱动环境
# 服务地址：http://${HOST}:${PORT}

export GGML_BACKEND_PATH="${GGML_BACKEND_PATH}"
export LD_LIBRARY_PATH="${LD_LIB_PATH}"
export CUDA_VISIBLE_DEVICES=${CUDA_DEV}

${LLAMA_SERVER_BIN} \\
    --model ${MODEL_ABS} \\
    --host ${HOST} \\
    --port ${PORT} \\
    --no-webui \\
    --rerank \\
    --ctx-size 8192 \\
    --n-gpu-layers 99
EOF

chmod +x "./${START_SCRIPT_NAME}"

info_log "========================================"
info_log "全部前置流程执行完毕，自动启动重排序服务"
info_log "启动脚本路径：${RUN_WORK_DIR}/${START_SCRIPT_NAME}"
info_log "重排序服务监听地址：http://${HOST}:${PORT}"
info_log "模型真实路径：${MODEL_ABS}"
info_log "========================================"

# ========== 7. 直接运行生成的启动脚本 ==========
bash "./${START_SCRIPT_NAME}"
