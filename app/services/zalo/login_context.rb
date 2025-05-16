module Zalo
  class LoginContext
    attr_accessor :logging, :cookie_jar, :user_agent

    def initialize
      @logging = false
      @cookie_jar = {}
      @user_agent = nil
    end

    def log_info(message)
      @logger&.info("[Zalo::LoginContext] #{message}") if logging
    end

    def log_error(message)
      @logger&.error("[Zalo::LoginContext] #{message}") if logging
    end

    def set_logger(logger)
      @logger = logger
    end
  end
end
