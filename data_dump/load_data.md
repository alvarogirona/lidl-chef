To load the database with pre-processed embeddings run:

```
cat lidl_chef_data.dump | docker exec -i pgvector pg_restore -U postgres -d lidl_chef_dev --clean --if-exists
```
