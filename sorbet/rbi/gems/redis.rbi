# This file is autogenerated. Do not edit it by hand. Regenerate it with:
#   srb rbi gems

# typed: strict
#
# If you would like to make changes to this file, great! Please create the gem's shim here:
#
#   https://github.com/sorbet/sorbet-typed/new/master?filename=lib/redis/all/redis.rbi
#
# redis-5.0.6

class Redis
  def _client; end
  def _subscription(method, timeout, channels, block); end
  def close; end
  def connected?; end
  def connection; end
  def disconnect!; end
  def dup; end
  def id; end
  def initialize(options = nil); end
  def initialize_client(options); end
  def inspect; end
  def pipelined; end
  def self.deprecate!(message); end
  def self.raise_deprecations; end
  def self.raise_deprecations=(arg0); end
  def self.silence_deprecations; end
  def self.silence_deprecations=(arg0); end
  def send_blocking_command(command, timeout, &block); end
  def send_command(command, &block); end
  def synchronize; end
  def with; end
  def without_reconnect(&block); end
  include Redis::Commands
end
class Redis::BaseError < StandardError
end
class Redis::ProtocolError < Redis::BaseError
  def initialize(reply_type); end
end
class Redis::CommandError < Redis::BaseError
end
class Redis::PermissionError < Redis::CommandError
end
class Redis::WrongTypeError < Redis::CommandError
end
class Redis::OutOfMemoryError < Redis::CommandError
end
class Redis::BaseConnectionError < Redis::BaseError
end
class Redis::CannotConnectError < Redis::BaseConnectionError
end
class Redis::ConnectionError < Redis::BaseConnectionError
end
class Redis::TimeoutError < Redis::BaseConnectionError
end
class Redis::InheritedError < Redis::BaseConnectionError
end
class Redis::ReadOnlyError < Redis::BaseConnectionError
end
class Redis::InvalidClientOptionError < Redis::BaseError
end
class Redis::SubscriptionError < Redis::BaseError
end
module Redis::Commands
  def call(*command); end
  def method_missing(*command); end
  def sentinel(subcommand, *args); end
  include Redis::Commands::Bitmaps
  include Redis::Commands::Cluster
  include Redis::Commands::Connection
  include Redis::Commands::Geo
  include Redis::Commands::Hashes
  include Redis::Commands::HyperLogLog
  include Redis::Commands::Keys
  include Redis::Commands::Lists
  include Redis::Commands::Pubsub
  include Redis::Commands::Scripting
  include Redis::Commands::Server
  include Redis::Commands::Sets
  include Redis::Commands::SortedSets
  include Redis::Commands::Streams
  include Redis::Commands::Strings
  include Redis::Commands::Transactions
end
module Redis::Commands::Bitmaps
  def bitcount(key, start = nil, stop = nil); end
  def bitop(operation, destkey, *keys); end
  def bitpos(key, bit, start = nil, stop = nil); end
  def getbit(key, offset); end
  def setbit(key, offset, value); end
end
module Redis::Commands::Cluster
  def asking; end
  def cluster(subcommand, *args); end
end
module Redis::Commands::Connection
  def auth(*args); end
  def echo(value); end
  def ping(message = nil); end
  def quit; end
  def select(db); end
end
module Redis::Commands::Geo
  def _geoarguments(*args, options: nil, sort: nil, count: nil); end
  def geoadd(key, *member); end
  def geodist(key, member1, member2, unit = nil); end
  def geohash(key, member); end
  def geopos(key, member); end
  def georadius(*args, **geoptions); end
  def georadiusbymember(*args, **geoptions); end
end
module Redis::Commands::Hashes
  def hdel(key, *fields); end
  def hexists(key, field); end
  def hget(key, field); end
  def hgetall(key); end
  def hincrby(key, field, increment); end
  def hincrbyfloat(key, field, increment); end
  def hkeys(key); end
  def hlen(key); end
  def hmget(key, *fields, &blk); end
  def hmset(key, *attrs); end
  def hrandfield(key, count = nil, withvalues: nil, with_values: nil); end
  def hscan(key, cursor, **options); end
  def hscan_each(key, **options, &block); end
  def hset(key, *attrs); end
  def hsetnx(key, field, value); end
  def hvals(key); end
  def mapped_hmget(key, *fields); end
  def mapped_hmset(key, hash); end
end
module Redis::Commands::HyperLogLog
  def pfadd(key, member); end
  def pfcount(*keys); end
  def pfmerge(dest_key, *source_key); end
end
module Redis::Commands::Keys
  def _scan(command, cursor, args, match: nil, count: nil, type: nil, &block); end
  def copy(source, destination, db: nil, replace: nil); end
  def del(*keys); end
  def dump(key); end
  def exists(*keys); end
  def exists?(*keys); end
  def expire(key, seconds, nx: nil, xx: nil, gt: nil, lt: nil); end
  def expireat(key, unix_time, nx: nil, xx: nil, gt: nil, lt: nil); end
  def keys(pattern = nil); end
  def migrate(key, options); end
  def move(key, db); end
  def object(*args); end
  def persist(key); end
  def pexpire(key, milliseconds, nx: nil, xx: nil, gt: nil, lt: nil); end
  def pexpireat(key, ms_unix_time, nx: nil, xx: nil, gt: nil, lt: nil); end
  def pttl(key); end
  def randomkey; end
  def rename(old_name, new_name); end
  def renamenx(old_name, new_name); end
  def restore(key, ttl, serialized_value, replace: nil); end
  def scan(cursor, **options); end
  def scan_each(**options, &block); end
  def sort(key, by: nil, limit: nil, get: nil, order: nil, store: nil); end
  def ttl(key); end
  def type(key); end
  def unlink(*keys); end
end
module Redis::Commands::Lists
  def _bpop(cmd, args, &blk); end
  def _normalize_move_wheres(where_source, where_destination); end
  def blmove(source, destination, where_source, where_destination, timeout: nil); end
  def blpop(*args); end
  def brpop(*args); end
  def brpoplpush(source, destination, timeout: nil); end
  def lindex(key, index); end
  def linsert(key, where, pivot, value); end
  def llen(key); end
  def lmove(source, destination, where_source, where_destination); end
  def lpop(key, count = nil); end
  def lpush(key, value); end
  def lpushx(key, value); end
  def lrange(key, start, stop); end
  def lrem(key, count, value); end
  def lset(key, index, value); end
  def ltrim(key, start, stop); end
  def rpop(key, count = nil); end
  def rpoplpush(source, destination); end
  def rpush(key, value); end
  def rpushx(key, value); end
end
module Redis::Commands::Pubsub
  def psubscribe(*channels, &block); end
  def psubscribe_with_timeout(timeout, *channels, &block); end
  def publish(channel, message); end
  def pubsub(subcommand, *args); end
  def punsubscribe(*channels); end
  def subscribe(*channels, &block); end
  def subscribe_with_timeout(timeout, *channels, &block); end
  def subscribed?; end
  def unsubscribe(*channels); end
end
module Redis::Commands::Scripting
  def _eval(cmd, args); end
  def eval(*args); end
  def evalsha(*args); end
  def script(subcommand, *args); end
end
module Redis::Commands::Server
  def bgrewriteaof; end
  def bgsave; end
  def client(subcommand, *args); end
  def config(action, *args); end
  def dbsize; end
  def debug(*args); end
  def flushall(options = nil); end
  def flushdb(options = nil); end
  def info(cmd = nil); end
  def lastsave; end
  def monitor; end
  def save; end
  def shutdown; end
  def slaveof(host, port); end
  def slowlog(subcommand, length = nil); end
  def sync; end
  def time; end
end
module Redis::Commands::Sets
  def sadd(key, *members); end
  def sadd?(key, *members); end
  def scard(key); end
  def sdiff(*keys); end
  def sdiffstore(destination, *keys); end
  def sinter(*keys); end
  def sinterstore(destination, *keys); end
  def sismember(key, member); end
  def smembers(key); end
  def smismember(key, *members); end
  def smove(source, destination, member); end
  def spop(key, count = nil); end
  def srandmember(key, count = nil); end
  def srem(key, *members); end
  def srem?(key, *members); end
  def sscan(key, cursor, **options); end
  def sscan_each(key, **options, &block); end
  def sunion(*keys); end
  def sunionstore(destination, *keys); end
end
module Redis::Commands::SortedSets
  def _zsets_operation(cmd, *keys, weights: nil, aggregate: nil, with_scores: nil); end
  def _zsets_operation_store(cmd, destination, keys, weights: nil, aggregate: nil); end
  def bzpopmax(*args); end
  def bzpopmin(*args); end
  def zadd(key, *args, nx: nil, xx: nil, lt: nil, gt: nil, ch: nil, incr: nil); end
  def zcard(key); end
  def zcount(key, min, max); end
  def zdiff(*keys, with_scores: nil); end
  def zdiffstore(*args, **); end
  def zincrby(key, increment, member); end
  def zinter(*args, **); end
  def zinterstore(*args, **); end
  def zlexcount(key, min, max); end
  def zmscore(key, *members); end
  def zpopmax(key, count = nil); end
  def zpopmin(key, count = nil); end
  def zrandmember(key, count = nil, withscores: nil, with_scores: nil); end
  def zrange(key, start, stop, byscore: nil, by_score: nil, bylex: nil, by_lex: nil, rev: nil, limit: nil, withscores: nil, with_scores: nil); end
  def zrangebylex(key, min, max, limit: nil); end
  def zrangebyscore(key, min, max, withscores: nil, with_scores: nil, limit: nil); end
  def zrangestore(dest_key, src_key, start, stop, byscore: nil, by_score: nil, bylex: nil, by_lex: nil, rev: nil, limit: nil); end
  def zrank(key, member); end
  def zrem(key, member); end
  def zremrangebyrank(key, start, stop); end
  def zremrangebyscore(key, min, max); end
  def zrevrange(key, start, stop, withscores: nil, with_scores: nil); end
  def zrevrangebylex(key, max, min, limit: nil); end
  def zrevrangebyscore(key, max, min, withscores: nil, with_scores: nil, limit: nil); end
  def zrevrank(key, member); end
  def zscan(key, cursor, **options); end
  def zscan_each(key, **options, &block); end
  def zscore(key, member); end
  def zunion(*args, **); end
  def zunionstore(*args, **); end
end
module Redis::Commands::Streams
  def _xread(args, keys, ids, blocking_timeout_msec); end
  def xack(key, group, *ids); end
  def xadd(key, entry, approximate: nil, maxlen: nil, nomkstream: nil, id: nil); end
  def xautoclaim(key, group, consumer, min_idle_time, start, count: nil, justid: nil); end
  def xclaim(key, group, consumer, min_idle_time, *ids, **opts); end
  def xdel(key, *ids); end
  def xgroup(subcommand, key, group, id_or_consumer = nil, mkstream: nil); end
  def xinfo(subcommand, key, group = nil); end
  def xlen(key); end
  def xpending(key, group, *args, idle: nil); end
  def xrange(key, start = nil, range_end = nil, count: nil); end
  def xread(keys, ids, count: nil, block: nil); end
  def xreadgroup(group, consumer, keys, ids, count: nil, block: nil, noack: nil); end
  def xrevrange(key, range_end = nil, start = nil, count: nil); end
  def xtrim(key, len_or_id, strategy: nil, approximate: nil, limit: nil); end
end
module Redis::Commands::Strings
  def append(key, value); end
  def decr(key); end
  def decrby(key, decrement); end
  def get(key); end
  def getdel(key); end
  def getex(key, ex: nil, px: nil, exat: nil, pxat: nil, persist: nil); end
  def getrange(key, start, stop); end
  def getset(key, value); end
  def incr(key); end
  def incrby(key, increment); end
  def incrbyfloat(key, increment); end
  def mapped_mget(*keys); end
  def mapped_mset(hash); end
  def mapped_msetnx(hash); end
  def mget(*keys, &blk); end
  def mset(*args); end
  def msetnx(*args); end
  def psetex(key, ttl, value); end
  def set(key, value, ex: nil, px: nil, exat: nil, pxat: nil, nx: nil, xx: nil, keepttl: nil, get: nil); end
  def setex(key, ttl, value); end
  def setnx(key, value); end
  def setrange(key, offset, value); end
  def strlen(key); end
end
module Redis::Commands::Transactions
  def discard; end
  def exec; end
  def multi; end
  def unwatch; end
  def watch(*keys); end
end
class Redis::Client < RedisClient
  def blocking_call_v(timeout, command, &block); end
  def call_v(command, &block); end
  def db; end
  def disable_reconnection(&block); end
  def host; end
  def id; end
  def inherit_socket!; end
  def multi; end
  def password; end
  def path; end
  def pipelined; end
  def port; end
  def self.config(**kwargs); end
  def self.sentinel(**kwargs); end
  def server_url; end
  def timeout; end
  def translate_error!(error); end
  def translate_error_class(error_class); end
  def username; end
end
class Redis::PipelinedConnection
  def db; end
  def db=(arg0); end
  def initialize(pipeline, futures = nil); end
  def multi; end
  def pipelined; end
  def send_blocking_command(command, timeout, &block); end
  def send_command(command, &block); end
  def synchronize; end
  include Redis::Commands
end
class Redis::MultiConnection < Redis::PipelinedConnection
  def multi; end
  def send_blocking_command(command, _timeout, &block); end
end
class Redis::FutureNotReady < RuntimeError
  def initialize; end
end
class Redis::Future < BasicObject
  def _set(object); end
  def class; end
  def initialize(command, coerce); end
  def inspect; end
  def is_a?(other); end
  def value; end
end
class Redis::MultiFuture < Redis::Future
  def _set(replies); end
  def initialize(futures); end
end
class Redis::SubscribedClient
  def call_v(command); end
  def close; end
  def initialize(client); end
  def psubscribe(*channels, &block); end
  def psubscribe_with_timeout(timeout, *channels, &block); end
  def punsubscribe(*channels); end
  def subscribe(*channels, &block); end
  def subscribe_with_timeout(timeout, *channels, &block); end
  def subscription(start, stop, channels, block, timeout = nil); end
  def unsubscribe(*channels); end
end
class Redis::Subscription
  def callbacks; end
  def initialize; end
  def message(&block); end
  def pmessage(&block); end
  def psubscribe(&block); end
  def punsubscribe(&block); end
  def subscribe(&block); end
  def unsubscribe(&block); end
end
class Redis::Deprecated < StandardError
end
module Redis::Connection
  def self.drivers; end
end
