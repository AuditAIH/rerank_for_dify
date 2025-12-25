# rerank_for_dify

```
mkdir -p llama.cpp_rerank && wget -O - https://github.com/AuditAIH/llama.cpp_rerank/releases/download/0.01/llama.cpp_rerank.tar.gz | tar -zxf - -C llama.cpp_rerank/

cd llama.cpp_rerank

export LD_LIBRARY_PATH=/usr/local/lib/ollama/cuda_v13:$LD_LIBRARY_PATH

#测试是否可以执行
./llama-server -h

wget https://www.modelscope.cn/models/gpustack/bge-reranker-v2-m3-GGUF/resolve/master/bge-reranker-v2-m3-FP16.gguf

./llama-server -m bge-reranker-v2-m3-FP16.gguf --port 11436 --reranking
```
