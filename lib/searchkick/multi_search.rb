module Searchkick
  class MultiSearch
    attr_reader :queries

    def initialize(queries, opaque_id: nil)
      @queries = queries
      @opaque_id = opaque_id
    end

    def perform
      if queries.any?
        perform_search(queries)
      end
    end

    private

    def perform_search(search_queries, perform_retry: true)
      params = {
        body: search_queries.flat_map { |q| [q.params.except(:body), q.body] }
      }
      params[:opaque_id] = @opaque_id if @opaque_id
      responses = client.msearch(params)["responses"]

      retry_queries = []
      search_queries.each_with_index do |query, i|
        if perform_retry && query.retry_misspellings?(responses[i])
          query.send(:prepare) # okay, since we don't want to expose this method outside Searchkick
          retry_queries << query
        else
          query.handle_response(responses[i])
        end
      end

      if retry_queries.any?
        perform_search(retry_queries, perform_retry: false)
      end

      search_queries
    end

    def client
      Searchkick.client(cluster)
    end

    # One msearch body goes to one cluster. Splitting across clusters would
    # change the notification payload and response correlation for a case the
    # gem has no caller for, so raise instead.
    def cluster
      return @cluster if defined?(@cluster)

      # canonicalized: an implicit default and an explicit :default are the
      # same cluster and must not be treated as a conflict
      clusters = queries.map { |q| Searchkick.canonical_cluster(q.cluster) }.uniq
      if clusters.size > 1
        raise Error, "Cannot multi search across clusters (#{clusters.map(&:inspect).join(", ")}) - group the queries by cluster and call Searchkick.multi_search once per cluster"
      end

      @cluster = clusters.first
    end
  end
end
