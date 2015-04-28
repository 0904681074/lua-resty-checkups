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

    server {
        listen 12357;
        location = /status {
            content_by_lua '
                ngx.sleep(3)
                ngx.status = 200
            ';
        }
    }

    init_by_lua '
        local config = require "config_key"
        local checkups = require "resty.checkups"
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
            ngx.sleep(4)
            local cb_ok = function(host, port)
                ngx.say(host .. ":" .. port)
                return 1
            end

            local ok, err = checkups.ready_ok("upyun", cb_ok, {cluster_key = {default="c1", backup="c2"}})
            if err then
                ngx.say(err)
            end
            local ok, err = checkups.ready_ok("upyun", cb_ok, {cluster_key = {default="c1", backup="c2"}})
            if err then
                ngx.say(err)
            end
            local ok, err = checkups.ready_ok("upyun", cb_ok, {cluster_key = {default="c1", backup="c2"}})
            if err then
                ngx.say(err)
            end
        ';
    }
--- request
GET /t
--- response_body
127.0.0.1:12354
127.0.0.1:12356
127.0.0.1:12354
--- grep_error_log eval: qr/failed to connect: 127.0.0.1:\d+ connection refused|failed to receive status line from 127.0.0.1:\d+: timeout/
--- grep_error_log_out
failed to receive status line from 127.0.0.1:12357: timeout
failed to receive status line from 127.0.0.1:12357: timeout
--- timeout: 10


=== TEST 2: fail with status code
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        access_log off;
        content_by_lua '
            local checkups = require "resty.checkups"
            checkups.create_checker()
            ngx.sleep(4)
            local cb = function(host, port)
                ngx.say(host .. ":" .. port)
                return {status = 502}
            end

            local ok, err  = checkups.ready_ok("upyun", cb, {cluster_key = {default="c1", backup="c2"}})
            if err then
                ngx.say(err)
            end
        ';
    }
--- request
GET /t
--- response_body
127.0.0.1:12354
127.0.0.1:12356
127.0.0.1:12356
127.0.0.1:12354
round robin: no servers available
--- grep_error_log eval: qr/failed to connect: 127.0.0.1:\d+ connection refused|failed to receive status line from 127.0.0.1:\d+: timeout/
--- grep_error_log_out
failed to receive status line from 127.0.0.1:12357: timeout
failed to receive status line from 127.0.0.1:12357: timeout
--- timeout: 10


=== TEST 3: backup cluster
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        access_log off;
        content_by_lua '
            local checkups = require "resty.checkups"
            checkups.create_checker()
            ngx.sleep(4)
            local cb = function(host, port)
                ngx.say(host .. ":" .. port)
                return {status = 502}
            end

            local ok, err  = checkups.ready_ok("upyun", cb, {cluster_key = {default="c1", backup="c2"}})
            if err then
                ngx.say(err)
            end
        ';
    }
--- request
GET /t
--- response_body
127.0.0.1:12354
127.0.0.1:12356
127.0.0.1:12356
127.0.0.1:12354
round robin: no servers available
--- grep_error_log eval: qr/failed to connect: 127.0.0.1:\d+ connection refused|failed to receive status line from 127.0.0.1:\d+: timeout/
--- grep_error_log_out
failed to receive status line from 127.0.0.1:12357: timeout
failed to receive status line from 127.0.0.1:12357: timeout
--- timeout: 10
