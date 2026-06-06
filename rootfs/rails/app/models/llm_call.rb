# Stores full request/response for every Anthropic API call.
# Written by AnthropicClient#call_llm, one row per API call.
# Single source of truth for LLM cost tracking.
#
#   call_llm(**params)
#     ├─ anthropic_client.messages.create(...)
#     ├─ LlmCall.create!(...) ← full request + response
#     │    └─ rescue => e → log warning, continue
#     └─ return raw response
#
class LlmCall < ApplicationRecord
  belongs_to :upload, optional: true

  scope :recent, -> { order(created_at: :desc) }
  scope :by_service, ->(name) { where(service_name: name) }
  scope :by_model, ->(name) { where(model: name) }
  scope :by_upload, ->(upload) { where(upload: upload) }

  # List view columns (excludes large text fields)
  LIST_COLUMNS = %i[id upload_id service_name model max_tokens stop_reason
                    input_tokens output_tokens cost_cents duration_ms created_at].freeze

  def self.total_cost_cents(since: nil)
    scope = since ? where("created_at >= ?", since) : all
    scope.sum(:cost_cents)
  end

  def self.total_tokens(since: nil)
    scope = since ? where("created_at >= ?", since) : all
    scope.sum(:input_tokens) + scope.sum(:output_tokens)
  end

  def self.cost_by_service(since: nil)
    scope = since ? where("created_at >= ?", since) : all
    scope.group(:service_name).sum(:cost_cents)
  end

  def self.cost_by_model(since: nil)
    scope = since ? where("created_at >= ?", since) : all
    scope.group(:model).sum(:cost_cents)
  end
end
