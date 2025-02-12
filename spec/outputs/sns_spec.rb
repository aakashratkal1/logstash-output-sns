# encoding: utf-8
require "logstash/devutils/rspec/spec_helper"
require 'logstash/outputs/sns'
require 'logstash/event'
require "logstash/plugin_mixins/aws_config"

require "aws-sdk" # TODO: Why is this not automatically brought in by the aws_config plugin?

describe LogStash::Outputs::Sns do
  let(:arn) { "arn:aws:sns:us-east-1:999999999:logstash-test-sns-topic" }
  let(:sns_subject) { "The Plain in Spain" }
  let (:default_message_attribute) { "NO_MESSAGE_ATTRIBUTES" }
  let(:sns_message) { "That's where the rain falls, plainly." }
  let (:sns_message_attribute) {'{"channel": "product channel"}'}
  let(:mock_client) { double("Aws::SNS::Client") }
  let(:instance) {
    allow(Aws::SNS::Client).to receive(:new).and_return(mock_client)
    inst = LogStash::Outputs::Sns.new
    allow(inst).to receive(:publish_boot_message_arn).and_return(nil)
    inst.register
    inst
  }

  describe "receiving an event" do
    let(:expected_subject) { double("expected_subject")}
    subject {
      inst = instance
      allow(inst).to receive(:send_sns_message).with(any_args)
      allow(inst).to receive(:event_subject).
                       with(any_args).
                       and_return(expected_subject)
      inst.receive(event)
      inst
    }

    shared_examples("publishing correctly") do
      it "should send a message to the correct ARN if the event has 'arn' set" do
        expect(subject).to have_received(:send_sns_message).with(arn, anything, anything, default_message_attribute)
      end

      it "should send the message" do
        expect(subject).to have_received(:send_sns_message).with(anything, anything, expected_message, default_message_attribute)
      end

      it "should send the subject" do
        expect(subject).to have_received(:send_sns_message).with(anything, expected_subject, anything, default_message_attribute)
      end
    end

    describe "with an explicit message" do
      let(:expected_subject) { sns_subject }
      let(:expected_message) { sns_message }
      let(:event) { LogStash::Event.new("sns" => arn, "sns_subject" => sns_subject,
                                        "sns_message" => sns_message) }
      include_examples("publishing correctly")
    end

    describe "without an explicit message" do
      # Testing codecs sucks. It'd be nice if codecs had to implement some sort of encode_sync method
      let(:expected_message) {
        c = subject.codec.clone
        result = nil;
        c.on_event {|event, encoded| result = encoded }
        c.encode(event)
        result
      }
      let(:event) { LogStash::Event.new("sns" => arn, "sns_subject" => sns_subject) }

      include_examples("publishing correctly")
    end
  end

  describe "determining the subject" do
    it "should return 'sns_subject' when set" do
      event = LogStash::Event.new("sns_subject" => "foo")
      expect(subject.send(:event_subject, event)).to eql("foo")
    end

    it "should return the sns subject as JSON if not a string" do
      event = LogStash::Event.new("sns_subject" => ["foo", "bar"])
      expect(subject.send(:event_subject, event)).to eql(LogStash::Json.dump(["foo", "bar"]))
    end

    it "should return the host if 'sns_subject' not set" do
      event = LogStash::Event.new("host" => "foo")
      expect(subject.send(:event_subject, event)).to eql("foo")
    end

    it "should return 'NO SUBJECT' when subject cannot be determined" do
      event = LogStash::Event.new("foo" => "bar")
      expect(subject.send(:event_subject, event)).to eql(LogStash::Outputs::Sns::NO_SUBJECT)
    end
  end

  describe "sending an SNS notification" do
    let(:good_publish_args) {
      {
        :topic_arn => arn,
        :subject => sns_subject,
        :message => sns_message,
        :message_attributes => sns_message_attribute
      }
    }
    let(:long_message) { "A" * (LogStash::Outputs::Sns::MAX_MESSAGE_SIZE_IN_BYTES + 1) }
    let(:long_subject) { "S" * (LogStash::Outputs::Sns::MAX_SUBJECT_SIZE_IN_CHARACTERS + 1) }
    subject { instance }

    it "should raise an ArgumentError if no arn is provided" do
      expect {
        subject.send(:send_sns_message, nil, sns_subject, sns_message)
      }.to raise_error(ArgumentError)
    end

    it "should send a well formed message through to SNS" do
      expect(mock_client).to receive(:publish).with(good_publish_args)
      subject.send(:send_sns_message, arn, sns_subject, sns_message, sns_message_attribute)
    end

    it "should attempt to publish a boot message" do
      expect(subject).to have_received(:publish_boot_message_arn).once
      x = case "foo"
            when "bar"
              "hello"
          end
    end

    it "should truncate long messages before sending" do
      max_size = LogStash::Outputs::Sns::MAX_MESSAGE_SIZE_IN_BYTES
      expect(mock_client).to receive(:publish) {|args|
                               expect(args[:message].bytesize).to eql(max_size)
                             }

      subject.send(:send_sns_message, arn, sns_subject, long_message, nil)
    end

    it "should truncate long subjects before sending" do
      max_size = LogStash::Outputs::Sns::MAX_SUBJECT_SIZE_IN_CHARACTERS
      expect(mock_client).to receive(:publish) {|args|
                               expect(args[:subject].bytesize).to eql(max_size)
                             }

      subject.send(:send_sns_message, arn, long_subject, sns_message, nil)
    end
  end

  describe "Consume message attributes" do

    it "Testing No message attributes" do
      event = LogStash::Event.new()
      response = subject.send(:event_message_attributes, event)
      expect(response).to eql(default_message_attribute)
    end

    it "Testing String message attributes" do
      event = LogStash::Event.new("sns_message_attribute" => '{"channel": "product channel"}')
      response = subject.send(:event_message_attributes, event)
      expect(response["channel"][:data_type]).to eql("String")
      expect(response["channel"][:string_value]).to eql("product channel")
    end

    it "Testing Number message attributes" do
      event = LogStash::Event.new("sns_message_attribute" => '{"channel": 123}')
      response = subject.send(:event_message_attributes, event)
      expect(response["channel"][:data_type]).to eql("Number")
      expect(response["channel"][:string_value]).to eql(123)
    end

    it "Testing String array message attributes" do
      event = LogStash::Event.new("sns_message_attribute" => '{"channel": ["product channel", "Test channel"]}')
      response = subject.send(:event_message_attributes, event)

      expect(response["channel"][:data_type]).to eql("String.Array")
      expect(response["channel"][:string_value]).to eql(["product channel", "Test channel"])
    end
  end


  describe "creating message attributes body for AWS SDK" do

    it "Testing String message attributes" do
      response = subject.send(:create_message_attribute_body, '{"channel": "product channel"}')
      expect(response["channel"][:data_type]).to eql("String")
      expect(response["channel"][:string_value]).to eql("product channel")
    end

    it "Testing Number message attributes" do
      response = subject.send(:create_message_attribute_body, '{"channel": 123}')
      expect(response["channel"][:data_type]).to eql("Number")
      expect(response["channel"][:string_value]).to eql(123)
    end

    it "Testing String array message attributes" do
      response = subject.send(:create_message_attribute_body, '{"channel": ["product channel", "Test channel"]}')
      expect(response["channel"][:data_type]).to eql("String.Array")
      expect(response["channel"][:string_value]).to eql(["product channel", "Test channel"])
    end

    it "Testing multiple string message attributes" do
      response = subject.send(:create_message_attribute_body, '{"channel": "product channel", "severity": 5}')
      expect(response["channel"][:data_type]).to eql("String")
      expect(response["channel"][:string_value]).to eql("product channel")
      expect(response["severity"][:data_type]).to eql("Number")
      expect(response["severity"][:string_value]).to eql(5)

    end
  end
end
