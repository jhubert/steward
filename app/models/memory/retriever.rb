module Memory
  class Retriever
    CHARS_PER_TOKEN = 4

    def initialize(conversation, budget: 800)
      @conversation = conversation
      @user = conversation.user
      @workspace = conversation.workspace
      @budget = budget
    end

    def call(query:)
      semantic = semantic_search(query)
      keyword = keyword_search(query)

      merged = merge_and_rank(semantic, keyword)
      return nil if merged.empty?

      format(merged)
    end

    # Returns raw MemoryItem records matching the query.
    # Used by the recall virtual tool for richer output formatting.
    # Options:
    #   category: filter by memory category (decision/preference/fact/commitment)
    #   user_ids: search across multiple users (for principal mode)
    def search(query:, category: nil, user_ids: nil)
      scope_override = if user_ids.present?
        MemoryItem.where(workspace: @workspace, user_id: user_ids)
      else
        base_scope
      end

      scope_override = scope_override.where(category: category) if category.present?

      semantic = semantic_search(query, scope: scope_override)
      keyword = keyword_search(query, scope: scope_override)

      merge_and_rank(semantic, keyword)
    end

    private

    def base_scope
      MemoryItem.where(workspace: @workspace, user: @user)
    end

    def semantic_search(query, scope: nil)
      scope ||= base_scope
      client = Rails.configuration.openai_client
      return [] if client.nil?

      response = client.embeddings(
        parameters: { model: "text-embedding-3-small", input: query }
      )

      query_vec = response.dig("data", 0, "embedding")
      return [] unless query_vec

      scope
        .with_embedding
        .nearest_neighbors(:embedding, query_vec, distance: :cosine)
        .limit(20)
        .to_a
    rescue StandardError => e
      Rails.logger.warn("[Memory::Retriever] Semantic search failed: #{e.message}")
      []
    end

    def keyword_search(query, scope: nil)
      scope ||= base_scope
      words = query.split(/\s+/).select { |w| w.length > 2 }.first(5)
      return [] if words.empty?

      conditions = words.map { "content ILIKE ?" }.join(" OR ")
      values = words.map { |w| "%#{sanitize_like(w)}%" }

      scope
        .where(conditions, *values)
        .order(created_at: :desc)
        .limit(20)
        .to_a
    end

    def merge_and_rank(semantic, keyword)
      all_items = {}

      # Score semantic results: rank-based (best match = 1.0, decays)
      semantic.each_with_index do |item, idx|
        score = (1.0 - (idx.to_f / [semantic.size, 1].max)) * 0.6
        all_items[item.id] = { item: item, score: score }
      end

      # Score keyword results: recency-based
      keyword.each_with_index do |item, idx|
        recency_score = (1.0 - (idx.to_f / [keyword.size, 1].max)) * 0.4
        if all_items[item.id]
          all_items[item.id][:score] += recency_score
        else
          all_items[item.id] = { item: item, score: recency_score }
        end
      end

      all_items.values
               .sort_by { |entry| -entry[:score] }
               .map { |entry| entry[:item] }
    end

    def format(items)
      char_limit = @budget * CHARS_PER_TOKEN
      chars_used = 0
      lines = []

      items.each do |item|
        line = "- [#{item.category}] #{item.content}"
        break if chars_used + line.length > char_limit
        chars_used += line.length
        lines << line
      end

      return nil if lines.empty?

      "## Long-Term Memory\n#{lines.join("\n")}"
    end

    def sanitize_like(string)
      string.gsub(/[%_\\]/) { |c| "\\#{c}" }
    end
  end
end
