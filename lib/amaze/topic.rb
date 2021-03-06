require File.dirname(__FILE__) + "/request"
require File.dirname(__FILE__) + "/exceptions"
require "eventmachine"
require "json"

class Topic
  
  attr_accessor :topic, :arn, :attributes

  def initialize(topic, arn='')
    @topic = topic
    @arn = arn
    @attributes = {}
  end
  
  def generate_request(params, &blk)
    deferrable = Request.new(params).process
    deferrable.callback do |resp|
      yield(deferrable, resp)
    end
    deferrable
  end

  def create
    params = {
      'Name' => "#{@topic}",
      'Action' => 'CreateTopic',
      'SignatureMethod' => 'HmacSHA256',
      'SignatureVersion' => 2,
      'Timestamp' => Time.now.iso8601,
      'AWSAccessKeyId' => AmazeSNS.akey
     }

    generate_request(params) do |dfr, response|
      parsed_response = Crack::XML.parse(response.response)
      @arn = parsed_response["CreateTopicResponse"]["CreateTopicResult"]["TopicArn"]
      AmazeSNS.topics[@topic.to_s] = self # add to hash
      AmazeSNS.topics.rehash
      dfr.succeed(self)
    end
  end

  # delete topic
  def delete
    params = {
      'TopicArn' => "#{arn}",
      'Action' => 'DeleteTopic',
      'SignatureMethod' => 'HmacSHA256',
      'SignatureVersion' => 2,
      'Timestamp' => Time.now.iso8601,
      'AWSAccessKeyId' => AmazeSNS.akey
     }

    generate_request(params) do |dfr, response|
      parsed_response = Crack::XML.parse(response.response)
      AmazeSNS.topics.delete("#{@topic}")
      AmazeSNS.topics.rehash
      dfr.succeed(parsed_response)
    end
  end

  # get attributes for topic from remote sns server
  # TopicArn -- the topic's ARN 
  # Owner -- the AWS account ID of the topic's owner 
  # Policy -- the JSON serialization of the topic's access control policy 
  # DisplayName -- the human-readable name used in the "From" field for notifications to email and email-json endpoints 
  
  def attrs
    params = {
      'TopicArn' => "#{arn}",
      'Action' => 'GetTopicAttributes',
      'SignatureMethod' => 'HmacSHA256',
      'SignatureVersion' => 2,
      'Timestamp' => Time.now.iso8601,
      'AWSAccessKeyId' => AmazeSNS.akey
     }

    generate_request(params) do |dfr, response|
      parsed_response = Crack::XML.parse(response.response) 
      res = parsed_response['GetTopicAttributesResponse']['GetTopicAttributesResult']['Attributes']["entry"]
      outcome = make_hash(res) #res["entry"] is an array of hashes - need to turn it into hash with key value
      self.attributes = outcome
      dfr.succeed(outcome)
    end
  end

  # The SetTopicAttributes action allows a topic owner to set an attribute of the topic to a new value.
  # only following attributes can be set:
  # TopicArn -- the topic's ARN 
  # Owner -- the AWS account ID of the topic's owner 
  # Policy -- the JSON serialization of the topic's access control policy 
  # DisplayName -- the human-readable name used in the "From" field for notifications to email and email-json endpoints
  
  def set_attrs(opts)
    params = {
      'AttributeName' => "#{opts[:name]}",
      'AttributeValue' => "#{opts[:value]}",
      'TopicArn' => "#{arn}",
      'Action' => 'SetTopicAttributes',
      'SignatureMethod' => 'HmacSHA256',
      'SignatureVersion' => 2,
      'Timestamp' => Time.now.iso8601,
      'AWSAccessKeyId' => AmazeSNS.akey
     }

    generate_request(params) do |dfr, response|
      parsed_response = Crack::XML.parse(response.response) 
      outcome = parsed_response['SetTopicAttributesResponse']['ResponseMetadata']['RequestId']
      dfr.succeed(outcome)
    end
  end

  # subscribe method
  def subscribe(opts)
    raise InvalidOptions unless ( !(opts.empty?) && opts.instance_of?(Hash) )
    params = {
      'TopicArn' => "#{arn}",
      'Endpoint' => "#{opts[:endpoint]}",
      'Protocol' => "#{opts[:protocol]}",
      'Action' => 'Subscribe',
      'SignatureMethod' => 'HmacSHA256',
      'SignatureVersion' => 2,
      'Timestamp' => Time.now.iso8601,
      'AWSAccessKeyId' => AmazeSNS.akey
    }

    generate_request(params) do |dfr, response|
      parsed_response = Crack::XML.parse(response.response)
      res = parsed_response['SubscribeResponse']['SubscribeResult']['SubscriptionArn']
      dfr.succeed(res)
    end
  end
  
  def unsubscribe(id)
    raise InvalidOptions unless ( !(id.empty?) && id.instance_of?(String) )
    params = {
      'SubscriptionArn' => "#{id}",
      'Action' => 'Unsubscribe',
      'SignatureMethod' => 'HmacSHA256',
      'SignatureVersion' => 2,
      'Timestamp' => Time.now.iso8601,
      'AWSAccessKeyId' => AmazeSNS.akey
    }

    generate_request(params) do |dfr, response|
      parsed_response = Crack::XML.parse(response.response)
      res = parsed_response['UnsubscribeResponse']['ResponseMetadata']['RequestId']
      dfr.succeed(res)
    end
  end
  
  
  # grabs list of subscriptions for this topic only
  def subscriptions
    params = {
      'TopicArn' => "#{arn}",
      'Action' => 'ListSubscriptionsByTopic',
      'SignatureMethod' => 'HmacSHA256',
      'SignatureVersion' => 2,
      'Timestamp' => Time.now.iso8601,
      'AWSAccessKeyId' => AmazeSNS.akey
    }

    generate_request(params) do |dfr, response|
      nh = {}
      parsed_response = Crack::XML.parse(response.response)
      arr = parsed_response['ListSubscriptionsByTopicResponse']['ListSubscriptionsByTopicResult']['Subscriptions']['member'] unless (parsed_response['ListSubscriptionsByTopicResponse']['ListSubscriptionsByTopicResult']['Subscriptions'].nil?)

      if !(arr.nil?) && (arr.instance_of?(Array))
        #temp fix for now
        nh = arr.inject({}) do |h,v|
          key = v["SubscriptionArn"].to_s
          value = v
          h[key.to_s] = value
          h
        end
      elsif !(arr.nil?) && (arr.instance_of?(Hash))
        # to deal with one subscription issue
        key = arr["SubscriptionArn"]
        arr.delete("SubscriptionArn")
        nh[key.to_s] = arr
      end
      dfr.succeed(nh)
    end
  end
  
  # The AddPermission action adds a statement to a topic's access control policy, granting access for the 
  # specified AWS accounts to the specified actions.
  
  def add_permission(opts)
    raise InvalidOptions unless ( !(opts.empty?) && opts.instance_of?(Hash) )
    params = {
      'TopicArn' => "#{arn}",
      'Label' => "#{opts[:label]}",
      'ActionName.member.1' => "#{opts[:action_name]}",
      'AWSAccountId.member.1' => "#{opts[:account_id]}",
      'Action' => 'AddPermission',
      'SignatureMethod' => 'HmacSHA256',
      'SignatureVersion' => 2,
      'Timestamp' => Time.now.iso8601,
      'AWSAccessKeyId' => AmazeSNS.akey
    }

    generate_request(params) do |dfr, response|
      parsed_response = Crack::XML.parse(response.response)
      res = parsed_response['AddPermissionResponse']['ResponseMetadata']['RequestId']
      dfr.succeed(res)
    end
  end
  
  # The RemovePermission action removes a statement from a topic's access control policy. 
  def remove_permission(label)
    raise InvalidOptions unless ( !(label.empty?) && label.instance_of?(String) )
    params = {
      'TopicArn' => "#{arn}",
      'Label' => "#{label}",
      'Action' => 'RemovePermission',
      'SignatureMethod' => 'HmacSHA256',
      'SignatureVersion' => 2,
      'Timestamp' => Time.now.iso8601,
      'AWSAccessKeyId' => AmazeSNS.akey
    }

    generate_request(params) do |dfr, response|
      parsed_response = Crack::XML.parse(response.response)
      res = parsed_response['RemovePermissionResponse']['ResponseMetadata']['RequestId']
      dfr.succeed(res)
    end
  end
  
  
  def publish(msg, subject='My First Message')
    raise InvalidOptions unless ( !(msg.empty?) && msg.instance_of?(String) )
    params = {
      'Subject' => subject,
      'TopicArn' => "#{arn}",
      "Message" => "#{msg}",
      'Action' => 'Publish',
      'SignatureMethod' => 'HmacSHA256',
      'SignatureVersion' => 2,
      'Timestamp' => Time.now.iso8601,
      'AWSAccessKeyId' => AmazeSNS.akey
    }

    generate_request(params) do |dfr, response|
      parsed_response = Crack::XML.parse(response.response)
      res = parsed_response['PublishResponse']['PublishResult']['MessageId']
      dfr.succeed(res)
    end
  end
  
  def confirm_subscription(token)
    raise InvalidOptions unless ( !(token.empty?) && token.instance_of?(String) )
    params = {
      'TopicArn' => "#{arn}",
      'Token' => "#{token}",
      'Action' => 'ConfirmSubscription',
      'SignatureMethod' => 'HmacSHA256',
      'SignatureVersion' => 2,
      'Timestamp' => Time.now.iso8601,
      'AWSAccessKeyId' => AmazeSNS.akey
    }

    generate_request(params) do |dfr, response|
      parsed_response = Crack::XML.parse(response.response)
      resp = parsed_response['ConfirmSubscriptionResponse']['ConfirmSubscriptionResult']['SubscriptionArn']
      id = parsed_response['ConfirmSubscriptionResponse']['ResponseMetadata']['RequestId']
      arr = [resp,id]
      dfr.succeed(arr)
    end
  end

  # Define a synchronous version for each call.
  %w{create delete attrs set_attrs subscribe unsubscribe subscriptions add_permission remove_permission publish confirm_subscription}.each do |func|
    class_eval(%Q{
        def sync_#{func}(*args)
          run_sync(lambda {#{func}(*args)})
        end
      })
  end
  
  
  private  
    def make_hash(arr)
      hash = arr.inject({}) do |h, v|
        (v["key"] == "Policy")? value = JSON.parse(v["value"]) : value = v["value"]
        key = v["key"].to_s
        h[key] = value
        h
      end
      hash
    end

    def run_sync(func_cb)
      if EventMachine.reactor_running?
        raise "Reactor loop cannot be running with synchronous calls."
      end
      result = nil
      EM.run {
        dfr = func_cb.call
        dfr.callback do |r|
          result = r
          EM.stop
        end
        dfr.errback do |e|
          raise e
        end
      }
      result
    end
end
