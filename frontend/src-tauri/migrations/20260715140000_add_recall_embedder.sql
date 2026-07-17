-- Recall embedder selection (F7). Which local embedder produces semantic-search vectors:
--   'apple'      — on-device Apple NLEmbedding (default; no download)
--   'nomic-gguf' — downloaded nomic-embed-text GGUF via a dedicated llama-helper sidecar
--   'ollama'     — loopback Ollama nomic-embed-text (optional)
-- NULL is treated as 'apple' in Rust.
ALTER TABLE settings ADD COLUMN recall_embedder TEXT;
