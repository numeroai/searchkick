module Searchkick
  class MultiSearch
    attr_reader :queries

    def initialize(queries, opaque_id: nil)
      @queries = queries
      @opaque_id = opaque_id
    end

    def perform
      if queries.any?
        queries.group_by { |query| query.client.object_id }.each_value do |client_queries|
          client = client_queries.first.client
          perform_search(client_queries, client: client)
        end
        queries
      end
    end

    private

    def perform_search(search_queries, client:, perform_retry: true)
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
        perform_search(retry_queries, client: client, perform_retry: false)
      end

      search_queries
    end
  end
end
