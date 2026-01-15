cd ~/llama.cpp/build-rocm/bin && ./llama-server \
                                                  --model ~/.lmstudio/models/ggml-org/Qwen3-Reranker-0.6B-Q8_0-GGUF/qwen3-reranker-0.6b-q8_0.gguf \
                                                  --host 127.0.0.1 \
                                                  --port 8082 \
                                                  --parallel 20 \
                                                  --ctx-size 2048 \
                                                  --n-gpu-layers 20 \
                                                  --threads $(nproc) > /tmp/llama_server_rocm.log 2>&1