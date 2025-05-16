module Zalo
  class LoginContext
    attr_accessor :cookie_jar, :user_agent, :logging

    DEFAULT_USER_AGENT = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36'

    def initialize
      @cookie_jar = {} # Hash để lưu trữ cookies
      @user_agent = DEFAULT_USER_AGENT
      @logging = false
    end

    def log_info(*messages)
      puts messages.join(" ") if @logging
    end

    def log_error(message)
      STDERR.puts message if @logging
    end
  end
end
