# rerank_for_dify

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

# 启动服务，加载重排序模型并绑定11436端口
# Start server, load reranking model and bind port 11436
./llama-server -m bge-reranker-v2-m3-FP16.gguf --port 11436 --reranking
```
