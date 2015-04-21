# vim:set ft= ts=4 sw=4 et fdm=marker:
use lib 'lib';
use Test::Nginx::Socket;
use Cwd qw(cwd);
use Test::Nginx::Socket 'no_plan';

#repeat_each(2);

workers(4);

my $pwd = cwd();

our $HttpConfig = qq{
    lua_socket_log_errors off;
    lua_package_path "$pwd/../lua-resty-lock/?.lua;$pwd/lib/?.lua;$pwd/t/lib/?.lua;;";
    error_log logs/error.log debug;

    lua_shared_dict state 10m;
    lua_shared_dict mutex 1m;
    lua_shared_dict locks 1m;

    server {
        listen 12354;
        location = /status {
            return 200;
        }
    }

    server {
        listen 12355;
        location = /status {
            return 502;
        }
    }

    server {
        listen 12356;
        location = /status {
            return 404;
        }
    }

    init_by_lua '
        local config = require "config_unprotected_api"
        local checkups = require "resty.checkups"
        -- customize heartbeat callback
        config.api.heartbeat = function(host, port, ups)
            return checkups.STATUS_ERR, "down"
        end
        checkups.prepare_checker(config)
    ';

};

$ENV{TEST_NGINX_CHECK_LEAK} = 1;
$ENV{TEST_NGINX_USE_HUP} = 1;
$ENV{TEST_NGINX_RESOLVER} = '8.8.8.8';
#no_diff();
no_long_string();

run_tests();

__DATA__

=== TEST 1: http
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        access_log off;
        content_by_lua '
            local checkups = require "resty.checkups"
            checkups.create_checker()
            ngx.sleep(2)
            local cb_ok = function(host, port)
                ngx.say(host .. ":" .. port)
                return checkups.STATUS_OK
            end

            local ok, err = checkups.ready_ok("api", cb_ok)
            ngx.say(err)
            local ok, err = checkups.ready_ok("api", cb_ok)
            ngx.say(err)

            local st = checkups.get_status()
            ngx.say(st["cls:api"][2][1].status)
            ngx.say(st["cls:api"][2][1].msg)
            ngx.say(st["cls:api"][2][2].status)
            ngx.say(st["cls:api"][2][2].msg)
        ';
    }
--- request
GET /t
--- response_body
no servers available
no servers available
err
down
err
down
--- no_error_log
