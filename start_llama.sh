#!/bin/bash

# /root/models/bge-reranker-v2-m3-GGUF/bge-reranker-v2-m3-FP16.gguf
# /root/llama.cpp/Qwen3-Reranker-0.6B-Q8_0-GGUF/qwen3-reranker-0.6b-q8_0.gguf

/root/llama.cpp/build/bin/llama-server \
  --model /root/llama.cpp/Qwen3-Reranker-0.6B-Q8_0-GGUF/qwen3-reranker-0.6b-q8_0.gguf \
  --host 0.0.0.0 \
  --port 11435 \
  --no-webui \
  --rerank \
  --pooling rank \
  --ctx-size 8192 \
  --ubatch-size 4096 \
  --batch-size 4096 \
  --n-gpu-layers 64 \
  --threads 16 \
  --no-mmap \
  --verbose