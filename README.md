# rerank_for_dify

## 直接执行二进制程序

```
# 创建目录并下载解压预编译包，-p确保目录存在
# Create dir & download/extract precompiled package (-p ensures dir existence)
mkdir -p llama.cpp_rerank && wget -O - https://github.com/AuditAIH/llama.cpp_rerank/releases/download/0.01/llama.cpp_rerank.tar.gz | tar -zxf - -C llama.cpp_rerank/

# 切换工作目录到解压后的程序目录
# Switch working directory to the extracted program directory
cd llama.cpp_rerank

# 添加CUDA v13库路径，解决程序运行依赖
# Add CUDA v13 lib path to resolve program runtime dependencies
export LD_LIBRARY_PATH=/usr/local/lib/ollama/cuda_v13:$LD_LIBRARY_PATH

# 测试llama-server是否可执行，-h输出帮助信息
# Test if llama-server is executable, -h outputs help information
./llama-server -h

# 下载bge-reranker-v2-m3的FP16格式GGUF模型文件
# Download FP16-format GGUF model file of bge-reranker-v2-m3
wget https://www.modelscope.cn/models/gpustack/bge-reranker-v2-m3-GGUF/resolve/master/bge-reranker-v2-m3-FP16.gguf
# wget https://www.modelscope.cn/models/ggml-org/Qwen3-Reranker-0.6B-Q8_0-GGUF/resolve/master/qwen3-reranker-0.6b-q8_0.gguf

# 启动服务，加载重排序模型并绑定11436端口
# Start server, load reranking model and bind port 11436
./llama-server -m bge-reranker-v2-m3-FP16.gguf --port 11436 --reranking
```

## 或从源码编译
```
# 1、下载编译工具
sudo apt update && apt install -y cmake gcc g++ libcurl4-openssl-dev
```
如需下载cuda，apt install -y nvidia-cuda-toolkit [参考NVDIA官网](https://developer.nvidia.com/cuda-13-0-2-download-archive?target_os=Linux&target_arch=x86_64&Distribution=Ubuntu&target_version=24.04&target_type=deb_local)
```
# 下载最新版本的llama.cpp (指定截止今日的标签）
git clone -b b7524 --depth 1 https://github.com/ggml-org/llama.cpp

cd llama.cpp

cmake -B build -DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release

# 2. 并行编译（核心加速！-j 后接线程数，$(nproc) 自动获取 CPU 核心数）
cmake --build build --config Release -j$(nproc)
```
编译完成后，运行
`./build/bin/llama-server -h` 测试

# 请求方式
```
curl -X POST http://host.docker.internal:11435/v1/rerank \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen3-reranker",
    "query": "Apple",
    "documents": [
      "apple",
      "banana",
      "fruit",
      "vegetable"
    ]
  }'
```
