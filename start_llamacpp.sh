cd ~/llama.cpp/build-vulkan/bin && ./llama-server \
  --model ~/.lmstudio/models/ggml-org/Qwen3-Reranker-0.6B-Q8_0-GGUF/qwen3-reranker-0.6b-q8_0.gguf \
  --host 127.0.0.1 \
  --port 8081 \
  --parallel 20 \
  --ctx-size 2048 \
  --n-gpu-layers 99 \
  --threads $(nproc) > /tmp/llama_server_vulkan.log 2>&1 &
echo "Vulkan server started with PID: $last_pid"