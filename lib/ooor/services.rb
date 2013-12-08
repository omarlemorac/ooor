#    OOOR: OpenObject On Ruby
#    Copyright (C) 2009-2013 Akretion LTDA (<http://www.akretion.com>).
#    Author: Raphaël Valyi
#    Licensed under the MIT license, see MIT-LICENSE file

module Ooor
  class Service
    def self.define_service(service, methods)
      methods.each do |meth|
        self.instance_eval do
          define_method meth do |*args|
            args[-1] = @connection.connection_session.merge(args[-1]) if args[-1].is_a? Hash
            @connection.get_rpc_client("#{@connection.base_url}/#{service}").call(meth, *args)
          end
        end
      end
    end

    def initialize(connection)
      @connection = connection
    end
  end


  class CommonService < Service
    def login(db, username, password)
      conn = @connection.get_jsonrpc2_client("#{@connection.base_jsonrpc2_url}")
      response = conn.post do |req|
        req.url '/web/session/authenticate' 
        req.headers['Content-Type'] = 'application/json'
        req.body = {method: 'call', params: { db: db, login: username, password: password}}.to_json
      end
      @connection.cookie = response.headers["set-cookie"]
      json_response = JSON.parse(response.body)
      @connection.session_id = json_response['result']['session_id']
      json_response['result']['uid']
    end

    define_service(:common, %w[ir_get ir_set ir_del about logout timezone_get get_available_updates get_migration_scripts get_server_environment login_message check_connectivity about get_stats list_http_services version authenticate get_available_updates set_loglevel get_os_time get_sqlcount])
  end


  class DbService < Service
    define_service(:db, %w[get_progress drop dump restore rename db_exist list change_admin_password list_lang server_version migrate_databases create_database duplicate_database])

    def create(password=@connection.config[:db_password], db_name='ooor_test', demo=true, lang='en_US', user_password=@connection.config[:password] || 'admin')
      @connection.logger.info "creating database #{db_name} this may take a while..."
      process_id = @connection.get_rpc_client(@connection.base_url + "/db").call("create", password, db_name, demo, lang, user_password)
      sleep(2)
      while get_progress(password, process_id)[0] != 1
        @connection.logger.info "..."
        sleep(0.5)
      end
      @connection.global_login(username: 'admin', password: user_password, database: db_name)
    end
  end


  class ObjectService < Service
    define_service(:object, %w[execute exec_workflow])

    def object_service(service, obj, method, *args)
      db, uid, pass, args = credentials_from_args(*args)
      @connection.logger.debug "OOOR object service: rpc_method: #{service}, db: #{db}, uid: #{uid}, pass: #, obj: #{obj}, method: #{method}, *args: #{args.inspect}"
      conn = @connection.get_jsonrpc2_client("#{@connection.base_jsonrpc2_url}")
      if args.last.is_a?(Hash)
        context = args.pop
      else
        context = {}
      end
      r = JSON.parse(conn.post do |req|
        req.headers['Cookie'] = @connection.cookie
        if service == :exec_workflow
          req.url '/web/dataset/exec_workflow'
          params = {"jsonrpc"=>"2.0","method"=>"call","params"=>{"model"=>obj, "id"=>args[0], "signal"=>method, "session_id" => @connection.session_id}, "id"=>"r42"}
        else
          req.url '/web/dataset/call_kw'
          params = {"jsonrpc"=>"2.0","method"=>"call","params"=>{"model"=>obj, "method"=> method, "kwargs"=>{}, "args"=>args, "context"=>context, "session_id" => @connection.session_id}, "id"=>"r42"}
        end
        req.headers['Content-Type'] = 'application/json'
        req.body = params.to_json
      end.body)
      if r["error"] #TODO wrap stack trace properly for debug
        m = "#{{'faultCode'=>r["error"]['data']['fault_code'], 'faultString'=>r["error"]['message']}}"
        raise OpenERPServerError.new(m, method, *args)
      else
        r["result"]
      end
      #send(service, db, uid, pass, obj, method, *args)
    end

    def credentials_from_context(*args)
      if args[-1][:context_index]
        i = args[-1][:context_index]
        args.delete_at -1
      else
        i = -1
      end
      c = HashWithIndifferentAccess.new(args[i])
      user_id = c.delete(:ooor_user_id) || @connection.config[:user_id]
      password = c.delete(:ooor_password) || @connection.config[:password]
      database = c.delete(:ooor_database) || @connection.config[:database]
      args[i] = @connection.connection_session.merge(c)
      return database, user_id, password, args
    end

    def credentials_from_args(*args)
      if args[-1].is_a? Hash #context
        database, user_id, password, args = credentials_from_context(*args)
      else
        user_id = @connection.config[:user_id]
        password = @connection.config[:password]
        database = @connection.config[:database]
      end
      if user_id.is_a?(String) && user_id.to_i == 0
        user_id = Ooor.cache.fetch("login-id-#{user_id}") do
          @connection.common.login(database, user_id, password)
        end
      end
      return database, user_id.to_i, password, args
    end
  end


  class ReportService < Service
    define_service(:report, %w[report report_get render_report])
  end

end
