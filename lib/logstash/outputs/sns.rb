# encoding: utf-8
require "logstash/outputs/base"
require "logstash/namespace"
require "logstash/plugin_mixins/aws_config"
require "logstash/util"
require "logstash/util/unicode_trimmer"

# SNS output.
#
# Send events to Amazon's Simple Notification Service, a hosted pub/sub
# framework.  It supports various subscription types, including email, HTTP/S, SMS, and SQS.
#
# For further documentation about the service see:
#
#   http://docs.amazonwebservices.com/sns/latest/api/
#
# This plugin looks for the following fields on events it receives:
#
#  * `sns` - If no ARN is found in the configuration file, this will be used as
#  the ARN to publish.
#  * `sns_subject` - The subject line that should be used.
#  Optional. The "%{host}" will be used if `sns_subject` is not present. The subject
#  will be truncated to 100 characters. If `sns_subject` is set to a non-string value a JSON version of that value will be saved.
#  * `sns_message` - Optional string of message to be sent. If this is set to a non-string value it will be encoded with the specified `codec`. If this is not set the entire event will be encoded with the codec.
#  with the @message truncated so that the length of the JSON fits in
#  `32768` bytes.
#
# ==== Upgrading to 2.0.0
#
# This plugin used to have a `format` option for controlling the encoding of messages prior to being sent to SNS.
# This plugin now uses the logstash standard <<codec,codec>> option for encoding instead.
# If you want the same 'plain' format as the v0/1 codec (`format => "plain"`) use `codec => "s3_plain"`.
#
class LogStash::Outputs::Sns < LogStash::Outputs::Base
  include LogStash::PluginMixins::AwsConfig::V2

  MAX_SUBJECT_SIZE_IN_CHARACTERS = 100
  MAX_MESSAGE_SIZE_IN_BYTES = 32768
  NO_SUBJECT = "NO SUBJECT"
  NO_MESSAGE_ATTRIBUTES = "NO_MESSAGE_ATTRIBUTES"

  config_name "sns"

  concurrency :shared

  # Optional ARN to send messages to. If you do not set this you must
  # include the `sns` field in your events to set the ARN on a per-message basis!
  config :arn, :validate => :string

  # When an ARN for an SNS topic is specified here, the message
  # "Logstash successfully booted" will be sent to it when this plugin
  # is registered.
  #
  # Example: arn:aws:sns:us-east-1:770975001275:logstash-testing
  #
  config :publish_boot_message_arn, :validate => :string

  public

  def register
    require "aws-sdk-resources"

    @sns = Aws::SNS::Client.new(aws_options_hash)

    publish_boot_message_arn()

    @codec.on_event do |event, encoded|
      send_sns_message(event_arn(event), event_subject(event), encoded, event_message_attributes(event))
    end
  end

  public

  def receive(event)


    if (sns_msg = event.get("sns_message"))
      if sns_msg.is_a?(String)
        send_sns_message(event_arn(event), event_subject(event), sns_msg, event_message_attributes(event))
      else
        @codec.encode(sns_msg)
      end
    else
      @codec.encode(event)
    end
  end

  private

  def publish_boot_message_arn
    # Try to publish a "Logstash booted" message to the ARN provided to
    # cause an error ASAP if the credentials are bad.
    if @publish_boot_message_arn
      send_sns_message(@publish_boot_message_arn, 'Logstash booted', 'Logstash successfully booted', NO_MESSAGE_ATTRIBUTES,)
    end
  end

  private

  def send_sns_message(arn, subject, message, message_attribute)
    raise ArgumentError, 'An SNS ARN is required.' unless arn

    trunc_subj = LogStash::Util::UnicodeTrimmer.trim_bytes(subject, MAX_SUBJECT_SIZE_IN_CHARACTERS)
    trunc_msg = LogStash::Util::UnicodeTrimmer.trim_bytes(message, MAX_MESSAGE_SIZE_IN_BYTES)
    publish_body = {
        :topic_arn => arn,
        :subject => trunc_subj,
        :message => trunc_msg
    }
    if message_attribute != NO_MESSAGE_ATTRIBUTES and message_attribute!=nil
      publish_body[:message_attributes] = message_attribute
      @logger.debug? && @logger.debug("Sending event to SNS topic [#{arn}] with subject [#{trunc_subj}] and message: #{trunc_msg}")
    end
    @sns.publish(publish_body)
  end

  private

  def event_subject(event)
    sns_subject = event.get("sns_subject")
    if sns_subject.is_a?(String)
      sns_subject
    elsif sns_subject
      LogStash::Json.dump(sns_subject)
    elsif event.get("host")
      event.get("host")
    else
      NO_SUBJECT
    end
  end

  private

  def event_message_attributes(event)
    sns_message_attribute = event.get("sns_message_attribute")
    if valid_json?(sns_message_attribute)
      return create_message_attribute_body(sns_message_attribute)
    else
      return NO_MESSAGE_ATTRIBUTES
    end
  end

  private

  def create_message_attribute_body(sns_message_attribute)
    message_attribute_in_json = JSON.parse(sns_message_attribute)
    message_attributes = {}
    message_attribute_in_json.each do |key, value|
      if value.is_a?(String)
        message_attributes[key] = {
            :data_type => "String",
            :string_value => value
        }
      elsif value.is_a?(Numeric)
        message_attributes[key] = {
            :data_type => "Number",
            :string_value => value
        }
      elsif value.is_a?(Array)
        if value.all? {|i| i.is_a?(String)}
          message_attributes[key] = {
              :data_type => "String.Array",
              :string_value => value
          }
        else
          @logger.error("Non string array is being sent in message attributes. Message Attributes: #{sns_message_attribute}")
        end
      end
    end
    return message_attributes
  end

  private

  def valid_json?(json)
    unless json.nil? || json.empty?
      JSON.parse(json)
      return true
    else
      return false
    end
  rescue JSON::ParserError => e
    @logger.error("Error while parsing message attributes. Message Attributes: #{e}")
    return false
  end

  private

  def event_arn(event)
    event.get("sns") || @arn
  end
end
