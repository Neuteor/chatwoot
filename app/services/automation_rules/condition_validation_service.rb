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
      return false unless valid_condition?(condition) && valid_query_operator?(condition) && valid_numeric_condition?(condition)
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
      custom_attribute_present?(key, condition['custom_attribute_type'])
    end
  end

    def operation_valid?(condition, filter)
    filter_operator = condition['filter_operator']

    # attribute changed is a special case
    return true if filter_operator == 'attribute_changed'
    return true if ['is_greater_than', 'is_less_than'].include?(filter_operator) && ['number', 'integer'].include?(filter['data_type'])

    filter['filter_operators'].include?(filter_operator)
  end

  def custom_attribute_present?(attribute_key, attribute_model)
    attribute_model = attribute_model.presence || self.class::ATTRIBUTE_MODEL

    @account.custom_attribute_definitions.where(
      attribute_model: attribute_model
    ).find_by(attribute_key: attribute_key).present?
  end

  def valid_numeric_condition?(condition)
    is_numeric_operator = ['is_greater_than', 'is_less_than'].include?(condition['filter_operator'])

    is_numeric_attribute = false
    key = condition['attribute_key']
    attribute_model = condition['custom_attribute_type'].presence || self.class::ATTRIBUTE_MODEL
    custom_attribute = @account.custom_attribute_definitions.find_by(
      attribute_key: key,
      attribute_model: attribute_model
    )
    if custom_attribute && custom_attribute.attribute_display_type == 'number'
      is_numeric_attribute = true
    end

    if is_numeric_operator || is_numeric_attribute
      values = condition['values']
      return false if values.blank?

      values.each do |val|
        begin
          Float(val.to_s)
        rescue ArgumentError, TypeError
          return false
        end
      end
    end

    true
  end
end
