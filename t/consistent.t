# vim:set ft= ts=4 sw=4 et fdm=marker:
use lib 'lib';
use Test::Nginx::Socket;
use Cwd qw(cwd);

#repeat_each(2);

workers(4);

plan tests => repeat_each() * (blocks() * 2);

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

    server {
        listen 12360;
        location = /status {
            return 200;
        }
    }

    server {
        listen 12361;
        location = /status {
            return 200;
        }
    }

    init_by_lua '
        local config = require "config_hash"
        local checkups = require "resty.checkups"
        checkups.prepare_checker(config)
    ';

};

$ENV{TEST_NGINX_RESOLVER} = '8.8.8.8';
#no_diff();
no_long_string();

run_tests();

__DATA__

=== TEST 1: consistent hash
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        access_log off;
        content_by_lua '
            local checkups = require "resty.checkups"
            checkups.create_checker()
            ngx.sleep(1)
            local cb_ok = function(host, port)
                ngx.say(host .. ":" .. port)
                return 1
            end

            local ok, err = checkups.ready_ok("hash", cb_ok, {escape_uri = "/ab"})
            local ok, err = checkups.ready_ok("hash", cb_ok, {escape_uri = "/ab"})
            local ok, err = checkups.ready_ok("hash", cb_ok, {escape_uri = "/abc"})
            local ok, err = checkups.ready_ok("hash", cb_ok, {escape_uri = "/abc"})
        ';
    }
--- request
GET /t
--- response_body
127.0.0.1:12354
127.0.0.1:12354
127.0.0.1:12354
127.0.0.1:12354
