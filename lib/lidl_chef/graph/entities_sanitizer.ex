defmodule LidlChef.Graph.EntitiesSanitizer do
  import Ecto.Query
  alias LidlChef.Repo
  alias Arcana.Graph.{Entity, Relationship, EntityMention}

  def get_entity_stats do
    from(e in Arcana.Graph.Entity,
      group_by: fragment("lower(?)", e.name),
      having: count(e.id) > 1,
      select: %{
        name: fragment("lower(?)", e.name),
        count: count(e.id),
        ids: fragment("array_agg(?)", e.id)
      }
    )
    |> Repo.all()
    |> Map.new(fn %{name: name, count: count, ids: ids} ->
      {name, %{count: count, ids: ids}}
    end)
  end

  @doc """
  Merges duplicate entities (same name, different IDs) into a single entity.

  For each group of duplicates:
  - Keeps the first entity
  - Updates all relationships and entity mentions to point to the kept entity
  - Deletes the duplicate entities

  Returns {:ok, count} where count is the number of duplicate entities merged.
  """
  def merge_duplicate_entities do
    duplicates = get_entity_stats()

    if duplicates == %{} do
      IO.puts("No duplicate entities found")
      {:ok, 0}
    else
      IO.puts("Found #{map_size(duplicates)} entity names with duplicates")

      Repo.transaction(fn ->
        total_merged =
          Enum.reduce(duplicates, 0, fn {name, %{ids: ids}}, acc ->
            uuid_ids = Enum.map(ids, &Ecto.UUID.load!/1)
            [keep_id | merge_ids] = uuid_ids

            IO.puts(
              "Merging '#{name}': keeping #{keep_id}, removing #{length(merge_ids)} duplicates"
            )

            {source_count, _} =
              from(r in Relationship,
                where: r.source_id in ^merge_ids
              )
              |> Repo.update_all(set: [source_id: keep_id, updated_at: DateTime.utc_now()])

            {target_count, _} =
              from(r in Relationship,
                where: r.target_id in ^merge_ids
              )
              |> Repo.update_all(set: [target_id: keep_id, updated_at: DateTime.utc_now()])

            {mention_count, _} =
              from(m in EntityMention,
                where: m.entity_id in ^merge_ids
              )
              |> Repo.update_all(set: [entity_id: keep_id, updated_at: DateTime.utc_now()])

            IO.puts(
              "  Updated #{source_count} source relationships, #{target_count} target relationships, #{mention_count} mentions"
            )

            {deleted_count, _} =
              from(e in Entity,
                where: e.id in ^merge_ids
              )
              |> Repo.delete_all()

            IO.puts("  Deleted #{deleted_count} duplicate entities")

            acc + deleted_count
          end)

        IO.puts("\nTotal duplicate entities merged: #{total_merged}")
        total_merged
      end)
    end
  end
end
