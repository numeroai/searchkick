module Searchkick
  class ReindexV2Job < Searchkick.parent_job.constantize
    queue_as { Searchkick.queue_name }

    # cluster: pins this job to a cluster. Absent means unpinned - resolve the
    # model's configured cluster, which is the legacy behavior.
    def perform(class_name, id, method_name = nil, routing: nil, index_name: nil, cluster: nil, ignore_missing: nil, on_missing: nil, full_reindex_method_name: nil)
      on_missing = Searchkick.normalize_on_missing(on_missing, ignore_missing)
      model = Searchkick.load_model(class_name, allow_child: true)
      index = model.searchkick_index(name: index_name, cluster: cluster&.to_sym)
      # use should_index? to decide whether to index (not default scope)
      # just like saving inline
      # could use Searchkick.scope() in future
      # but keep for now for backwards compatibility
      model = model.unscoped if model.respond_to?(:unscoped)
      items = [{id: id, routing: routing}]
      RecordIndexer.new(index).reindex_items(model, items, method_name: method_name, on_missing: on_missing, single: true, full_reindex_method_name: full_reindex_method_name)
    end
  end
end
