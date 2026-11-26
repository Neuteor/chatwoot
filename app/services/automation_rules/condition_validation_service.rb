class AutomationRules::ConditionValidationService
  ATTRIBUTE_MODEL = 'conversation_attribute'.freeze

  def initialize(rule)
    @rule = rule
    @account = rule.account

    file = File.read('./lib/filters/filter_keys.yml')
    @filters = YAML.safe_load(file)

    @conversation_filters = @filters['conversations']
    @contact_filters = @filters['contacts']
    @message_filters = @filters['messages']
  end

  def perform
    @rule.conditions.each do |condition|
      return false unless valid_condition?(condition) && valid_query_operator?(condition)
    end

    true
  end

  private

  def valid_query_operator?(condition)
    query_operator = condition['query_operator']

    return true if query_operator.nil?
    return true if query_operator.empty?

    %w[AND OR].include?(query_operator.upcase)
  end

    def valid_condition?(condition) 
    key = condition['attribute_key']
    if key == Captain::AutomationConditionService::ATTRIBUTE_KEY
      return Captain::AutomationConditionService::OPERATORS.include?(condition['filter_operator'])
    end

    conversation_filter = @conversation_filters[key]
    contact_filter = @contact_filters[key]
    message_filter = @message_filters[key]

    if conversation_filter || contact_filter || message_filter
      operation_valid?(condition, conversation_filter || contact_filter || message_filter)
    else
      definition = custom_attribute_definition(key, condition['custom_attribute_type'])
      return false if definition.blank?

      if definition.attribute_display_type == 'number' || %w[greater_than less_than].include?(condition['filter_operator'])
        return false unless valid_numeric_values?(condition)
      end

      %w[equal_to not_equal_to greater_than less_than].include?(condition['filter_operator'])
    end
  end

  def valid_numeric_values?(condition)
    values = condition['values']
    return false if values.blank?

    values.all? { |v| valid_numeric?(v) }
  end

  def valid_numeric?(value)
    return true if value.is_a?(Numeric)
    return false if value.nil?
    !!Float(value) rescue false
  end

  def custom_attribute_definition(attribute_key, attribute_model)
    attribute_model = attribute_model.presence || self.class::ATTRIBUTE_MODEL

    @account.custom_attribute_definitions.where(
      attribute_model: attribute_model
    ).find_by(attribute_key: attribute_key)
  end

  def operation_valid?(condition, filter)
    filter_operator = condition['filter_operator']

    # attribute changed is a special case
    return true if filter_operator == 'attribute_changed'

    filter['filter_operators'].include?(filter_operator)
  end

  def custom_attribute_present?(attribute_key, attribute_model)
    custom_attribute_definition(attribute_key, attribute_model).present?
  end
end
