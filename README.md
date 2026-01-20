# LidlChef

## Pre-requisites

### Installing elixir

To install Elixir and Erlang into you machine follow this post:

[Setting up Erlang & Elixir on Mac OS using mise](https://dev.to/ciacka/setting-up-erlang-elixir-on-mac-os-using-mise-3bck)

### Install LM Studio

LM Studio allows to easily download and run local AI models on your machine. To install it run (might require admin privileges enabled to move it to applications):

```
brew install --cask lm-studio
```

#### Downloading required models

The server requires the following models to be downloaded in LM Studio (you might need to disable ZScaler Internet Secutiry temporary):
- `qwen3-reranker-0.6b` (published by `ggml-org`)
- `qwen/qwen3-4b-2507` (published by `qwen`)

### PostgreSQL with pg_vector

We need a running PostgreSQL instance with pg_vector installed, running in the `5431` port. One of the easiest ways is by using Docker:

```
docker run -d \
  --name pgvector \
  -e POSTGRES_PASSWORD=postgres \
  -p 5431:5432 \
  pgvector/pgvector:0.8.1-pg18-trixie
```

### Loading the recipes data dump

Under `./data_dump` there is a pre-processed dump of the recipes with processed embeddings for pg_vector. It can be loaded into the database by running:

```
cat ./data_dump/lidl_chef_data.dump | docker exec -i pgvector pg_restore -U postgres -d lidl_chef_dev --clean --if-exists
```

## Start the server

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

### Dashboard endpoint

- The Arcana dashboard can be accessed from `http://localhost:4000/arcana`. There you can check the ingested recipes and perform some simple checks as search and llm ask.
