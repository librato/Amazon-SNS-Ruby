require "rubygems"
require 'crack/xml'
require 'ruby-debug'

require File.dirname(__FILE__) + "/helpers"
require File.dirname(__FILE__) + "/exceptions"

require 'em-http'


class Request
  
  attr_accessor :params, :options, :httpresponse
  
  def initialize(params, options={})
    @params = params
    @options = options
  end
  
  def process
    query_string = canonical_querystring(@params)

string_to_sign = "GET
#{AmazeSNS.host}
/
#{query_string}"
                
      hmac = HMAC::SHA256.new(AmazeSNS.skey)
      hmac.update( string_to_sign )
      signature = Base64.encode64(hmac.digest).chomp
      
      params['Signature'] = signature

      unless defined?(EventMachine) && EventMachine.reactor_running?
        raise AmazeSNSRuntimeError, "In order to use this you must be running inside an eventmachine loop"
      end
      
      require 'em-http' unless defined?(EventMachine::HttpRequest)
      
      deferrable = EM::DefaultDeferrable.new
      
      @httpresponse ||= http_class.new("https://#{AmazeSNS.host}/").get({
        :query => params, :timeout => 2
      })
      @httpresponse.callback{
        begin
          success_callback
          deferrable.succeed     
        rescue => e
          deferrable.fail(e)
        end 
      }
      @httpresponse.errback{ 
        error_callback
        deferrable.fail(AmazeSNSRuntimeError.new("A runtime error has occured: status code: #{@httpresponse.response_header.status}"))
      }
      deferrable
  end
  
  def http_class
    EventMachine::HttpRequest
  end
  
  
  def success_callback
    case @httpresponse.response_header.status
     when 403
       raise AuthorizationError
     when 500
       raise InternalError
     when 400
       raise InvalidParameterError
     when 404
       raise NotFoundError
     else
       call_user_success_handler
     end #end case
  end
  
  def call_user_success_handler
    @options[:on_success].call(httpresponse) if options[:on_success].respond_to?(:call)
  end
  
  def error_callback
    EventMachine.stop
    raise AmazeSNSRuntimeError.new("A runtime error has occured: status code: #{@httpresponse.response_header.status}")
  end
  
  
end
