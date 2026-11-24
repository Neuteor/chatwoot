require 'json'

class AutomationRules::ConditionsFilterService < FilterService
  ATTRIBUTE_MODEL = 'contact_attribute'.freeze

  def initialize(rule, conversation = nil, options = {})
    super([], nil)
    # assign rule, conversation and account to instance variables
    @rule = rule
    @conversation = conversation
    @account = conversation.account

    # setup filters from json file
    file = File.read('./lib/filters/filter_keys.yml')
    @filters = YAML.safe_load(file)

    @conversation_filters = @filters['conversations']
    @contact_filters = @filters['contacts']
    @message_filters = @filters['messages']

    @options = options
    @changed_attributes = options[:changed_attributes]
  end

  # Captain is asked only when its answer can change the outcome. AND and OR never negate a condition,
  # so a rule that gives the same result with every Captain condition unmet and met gives that result
  # whatever Captain would answer.
  def perform
    return false unless rule_valid?
    return matches?({}) if captain_indexes.empty?

    unmet_result = matches?(captain_indexes.index_with(false))
    return unmet_result if unmet_result == matches?(captain_indexes.index_with(true))

    matches?(Captain::AutomationConditionService.new(
      conditions: @rule.conditions, conversation: @conversation, message: @options[:message]
    ).perform)
  rescue StandardError => e
    Rails.logger.error "Error in AutomationRules::ConditionsFilterService: #{e.message}"
    Rails.logger.info "AutomationRules::ConditionsFilterService failed while processing rule #{@rule.id} for conversation #{@conversation.id}"
    false
  end

  def rule_valid?
    is_valid = AutomationRules::ConditionValidationService.new(@rule).perform
    Rails.logger.info "Automation rule condition validation failed for rule id: #{@rule.id}" unless is_valid
    @rule.authorization_error! unless is_valid

    is_valid
  end

  def filter_operation(query_hash, current_index)
    if query_hash[:filter_operator] == 'starts_with'
      @filter_values["value_#{current_index}"] = "#{string_filter_values(query_hash)}%"
      like_filter_string(query_hash[:filter_operator], current_index)
    else
      super
    end
  end

  def apply_filter(query_hash, current_index)
    if numeric_comparison?(query_hash)
      @query_string += numeric_query_string(query_hash, current_index)
      return
    end

    conversation_filter = @conversation_filters[query_hash['attribute_key']]
    contact_filter = @contact_filters[query_hash['attribute_key']]
    message_filter = @message_filters[query_hash['attribute_key']]

    if query_hash['attribute_key'] == Captain::AutomationConditionService::ATTRIBUTE_KEY
      @query_string += captain_query_string(query_hash, current_index)
    elsif conversation_filter
      @query_string += conversation_query_string('conversations', conversation_filter, query_hash.with_indifferent_access, current_index)
    elsif contact_filter
      @query_string += contact_query_string(contact_filter, query_hash.with_indifferent_access, current_index)
    elsif message_filter
      @query_string += message_query_string(message_filter, query_hash.with_indifferent_access, current_index)
    elsif custom_attribute(query_hash['attribute_key'], @account, query_hash['custom_attribute_type'])
      # send table name according to attribute key right now we are supporting contact based custom attribute filter
      @query_string += custom_attribute_query(query_hash.with_indifferent_access, query_hash['custom_attribute_type'], current_index)
    end
  end

  # If attribute_changed type filter is present perform this against array
  def perform_attribute_changed_filter(records)
    @attribute_changed_records = []
    current_attribute_changed_record = base_relation
    filter_based_on_attribute_change(records, current_attribute_changed_record)

    @attribute_changed_records.uniq
  end

  # Loop through attribute_changed_query_filter
  def filter_based_on_attribute_change(records, current_attribute_changed_record)
    @attribute_changed_query_filter.each do |filter|
      @changed_attributes = @changed_attributes.with_indifferent_access
      changed_attribute = @changed_attributes[filter['attribute_key']].presence

      if changed_attribute[0].in?(filter['values']['from']) && changed_attribute[1].in?(filter['values']['to'])
        @attribute_changed_records = attribute_changed_filter_query(filter, records, current_attribute_changed_record)
      end
      current_attribute_changed_record = @attribute_changed_records
    end
  end

  # We intersect with the record if query_operator-AND is present and union if query_operator-OR is present
  def attribute_changed_filter_query(filter, records, current_attribute_changed_record)
    if filter['query_operator'] == 'AND'
      @attribute_changed_records + (current_attribute_changed_record & records)
    else
      @attribute_changed_records + (current_attribute_changed_record | records)
    end
  end

  # Captain's answer is bound as a boolean so it takes part in the AND/OR chain like any SQL condition.
  def captain_query_string(query_hash, current_index)
    @filter_values["value_#{current_index}"] = @captain_answers[current_index]
    " :value_#{current_index} #{query_hash['query_operator']} "
  end

  def message_query_string(current_filter, query_hash, current_index)
    attribute_key = query_hash['attribute_key']
    query_operator = query_hash['query_operator']

    attribute_key = 'processed_message_content' if attribute_key == 'content'
    attribute_key = 'private' if attribute_key == 'private_note'

    filter_operator_value = filter_operation(query_hash, current_index)

    case current_filter['attribute_type']
    when 'standard'
      if current_filter['data_type'] == 'text'
        " LOWER(messages.#{attribute_key}) #{filter_operator_value} #{query_operator} "
      else
        " messages.#{attribute_key} #{filter_operator_value} #{query_operator} "
      end
    end
  end

  # This will be used in future for contact automation rule
  def contact_query_string(current_filter, query_hash, current_index)
    attribute_key = query_hash['attribute_key']
    query_operator = query_hash['query_operator']

    filter_operator_value = filter_operation(query_hash, current_index)

    case current_filter['attribute_type']
    when 'additional_attributes'
      " contacts.additional_attributes ->> '#{attribute_key}' #{filter_operator_value} #{query_operator} "
    when 'standard'
      " contacts.#{attribute_key} #{filter_operator_value} #{query_operator} "
    end
  end

  def conversation_query_string(table_name, current_filter, query_hash, current_index)
    attribute_key = query_hash['attribute_key']
    query_operator = query_hash['query_operator']

    if attribute_key == 'assignee_id' && query_hash['filter_operator'].in?(%w[is_present is_not_present])
      return assignee_presence_filter(table_name, query_hash)
    end

    return " #{tag_filter_query(query_hash, current_index)} " if attribute_key == 'labels'

    filter_operator_value = filter_operation(query_hash, current_index)

    case current_filter['attribute_type']
    when 'additional_attributes'
      " #{table_name}.additional_attributes ->> '#{attribute_key}' #{filter_operator_value} #{query_operator} "
    when 'standard'
      " #{table_name}.#{attribute_key} #{filter_operator_value} #{query_operator} "
    end
  end

  private

  def numeric_comparison?(query_hash)
    operator = query_hash['filter_operator']
    return true if ['is_greater_than', 'is_less_than'].include?(operator)

    attribute_key = query_hash['attribute_key']
    attribute_model = query_hash['custom_attribute_type'].presence || 'conversation_attribute'
    custom_attribute_def = @account.custom_attribute_definitions.find_by(
      attribute_key: attribute_key,
      attribute_model: attribute_model
    )
    if custom_attribute_def && custom_attribute_def.attribute_display_type == 'number'
      return true
    end

    false
  end

  def numeric_column_expression(query_hash)
    attribute_key = query_hash['attribute_key']
    attribute_model = query_hash['custom_attribute_type'].presence
    if attribute_model.present?
      table_name = attribute_model == 'contact_attribute' ? 'contacts' : 'conversations'
      return "#{table_name}.additional_attributes ->> '#{attribute_key}'"
    end

    conversation_filter = @conversation_filters[attribute_key]
    contact_filter = @contact_filters[attribute_key]
    message_filter = @message_filters[attribute_key]

    if conversation_filter
      if conversation_filter['attribute_type'] == 'additional_attributes'
        "conversations.additional_attributes ->> '#{attribute_key}'"
      else
        "conversations.#{attribute_key}"
      end
    elsif contact_filter
      if contact_filter['attribute_type'] == 'additional_attributes'
        "contacts.additional_attributes ->> '#{attribute_key}'"
      else
        "contacts.#{attribute_key}"
      end
    elsif message_filter
      attribute_key = 'processed_message_content' if attribute_key == 'content'
      attribute_key = 'private' if attribute_key == 'private_note'
      "messages.#{attribute_key}"
    else
      custom_attr = @account.custom_attribute_definitions.find_by(attribute_key: attribute_key)
      if custom_attr
        table_name = custom_attr.attribute_model == 'contact_attribute' ? 'contacts' : 'conversations'
        "#{table_name}.additional_attributes ->> '#{attribute_key}'"
      else
        nil
      end
    end
  end

  def numeric_query_string(query_hash, current_index)
    query_operator = query_hash['query_operator']
    column_expr = numeric_column_expression(query_hash)

    if column_expr.blank?
      return " FALSE #{query_operator} "
    end

    threshold_val = query_hash['values']&.first
    if threshold_val.blank?
      return " FALSE #{query_operator} "
    end

    @filter_values["value_#{current_index}"] = threshold_val.to_f

    sql_operator = case query_hash['filter_operator']
                   when 'equal_to' then '='
                   when 'not_equal_to' then '!='
                   when 'is_greater_than' then '>'
                   when 'is_less_than' then '<'
                   else nil
                   end

    if sql_operator.nil?
      return " FALSE #{query_operator} "
    end

    " (CASE WHEN (#{column_expr})::text ~ '^-?[0-9]+(\\.[0-9]+)?$' THEN (#{column_expr})::numeric #{sql_operator} :value_#{current_index} ELSE FALSE END) #{query_operator} "
  end

  def captain_indexes
    @captain_indexes ||= @rule.conditions.each_index.select do |index|
      @rule.conditions[index]['attribute_key'] == Captain::AutomationConditionService::ATTRIBUTE_KEY
    end
  end

  def matches?(captain_answers)
    @captain_answers = captain_answers
    @query_string = ''
    @filter_values = {}
    @attribute_changed_query_filter = []

    @rule.conditions.each_with_index do |query_hash, current_index|
      @attribute_changed_query_filter << query_hash and next if query_hash['filter_operator'] == 'attribute_changed'

      apply_filter(query_hash, current_index)
    end

    records = base_relation.where(@query_string, @filter_values.with_indifferent_access)
    records = perform_attribute_changed_filter(records) if @attribute_changed_query_filter.any?

    records.any?
  end

  def filter_config
    {
      entity: 'Conversation',
      table_name: 'conversations'
    }
  end

  def base_relation
    records = Conversation.where(id: @conversation.id).joins(
      'LEFT OUTER JOIN contacts on conversations.contact_id = contacts.id'
    ).joins(
      'LEFT OUTER JOIN messages on messages.conversation_id = conversations.id'
    )

    records = records.where(messages: { id: @options[:message].id }) if @options[:message].present?
    records
  end
end
