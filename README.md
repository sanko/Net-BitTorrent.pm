# NAME

Net::BitTorrent - Complete, Modern BitTorrent Client Library

# SYNOPSIS

```perl
use v5.40;
use Net::BitTorrent;
use Net::BitTorrent::Types qw[:encryption];

# Initialize the client
my $client = Net::BitTorrent->new(
    user_agent   => "MyClient/1.0",
    upnp_enabled => 1,
    encryption   => ENCRYPTION_REQUIRED # or 'required'
);

# Unified add() handles magnets, .torrents, or v1/v2 infohashes
# Supports 20/32-byte binary or 40/64-character hex strings
my $torrent = $client->add("magnet:?xt=urn:btih:...", "./downloads");

# Simple event handling
$client->on(torrent_added => sub ($nb, $t) {
    say "New swarm added: " . $t->name;
    $t->start();
});

# Advanced: Manual event loop integration
# while (1) {
#     $client->tick(0.1);
#     select(undef, undef, undef, 0.1);
# }

# Wait for all downloads to finish
$client->wait();

# Graceful shutdown
$client->shutdown();
```

# DESCRIPTION

`Net::BitTorrent` is a comprehensive, high-performance BitTorrent client library rewritten from the ground up for
**Modern Perl (v5.40+)** using the native `class` feature.

The library is designed around three core principles:

- 1. Loop-agnosticism: The core logic is decoupled from I/O. You can drive it with a simple `while` loop, integrate it into `IO::Async`, `Mojo::IOLoop`, or even run it in a synchronous environment.
- 2. BitTorrent v2 first: Full support for **BEP 52 (BitTorrent v2)**, including SHA-256 infohashes, Merkle tree block verification, and hybrid v1/v2 swarms.
- 3. Security: Features like **BEP 42 (DHT Security)**, **Protocol Encryption (MSE/PE)**, and peer reputation tracking are built-in and enabled by default.

## How Everything Fits Together

Net::BitTorrent uses a hierarchical architecture to manage the complexities of the protocol:

### 1. The Client ([Net::BitTorrent](https://metacpan.org/pod/Net%3A%3ABitTorrent))

The entry point. It manages multiple swarms, global rate limits, decentralized discovery (DHT/LPD), and unified UDP
packet routing. It also provides a centralized "hashing queue" to prevent block verification from starving your CPU.

### 2. Torrents ([Net::BitTorrent::Torrent](https://metacpan.org/pod/Net%3A%3ABitTorrent%3A%3ATorrent))

Orchestrates a single swarm. It manages its own list of discovered peers, the Piece Picker (rarest-first logic), and
communicates with the Trackers. It acts as the bridge between the network (Peers) and the local disk (Storage).

### 3. Peers ([Net::BitTorrent::Peer](https://metacpan.org/pod/Net%3A%3ABitTorrent%3A%3APeer))

Tracks the state of a single connection (choking, interested, transfer rates). It uses a **Protocol Handler** to speak
the wire protocol and a **Net::BitTorrent::Transport** (TCP or uTP) to move bytes.

### 4. Storage ([Net::BitTorrent::Storage](https://metacpan.org/pod/Net%3A%3ABitTorrent%3A%3AStorage))

Manages files on disk. It uses Merkle trees for per-block verification (v2) and handles the "virtual contiguous file"
mapping required for v1 compatibility. It includes an asynchronous disk cache to keep the main loop fast.

# METHODS

## `new( %params )`

Creates a new client instance.

```perl
my $client = Net::BitTorrent->new(
    port         => 6881,
    encryption   => 'required', # 'none', 'preferred', or 'required'
    upnp_enabled => 1
);
```

- **Use Case**: Initializing the BitTorrent engine with custom configuration.
- **Parameters**:
`port` (Int),
`user_agent` (Str),
`encryption` (Str or Constant: ENCRYPTION\_NONE, ENCRYPTION\_PREFERRED, ENCRYPTION\_REQUIRED),
`upnp_enabled` (Bool),
and various `bepXX` toggles (e.g., `bep05 =` 0> to disable DHT).
- **Returns**: A new `Net::BitTorrent` instance.

## `on( $event, $callback )`

Registers a global callback for client-level events.

```perl
$client->on(torrent_added => sub ($nb, $torrent) {
    warn "Added: " . $torrent->name;
});
```

- **Use Case**: Reacting to system-wide changes or automating newly added swarms.
- **Parameters**: `$event` (Str), `$callback` (CodeRef).
- **Returns**: Nothing.
- **Events**:
`torrent_added`: Emitted whenever a new swarm is registered.

## `add( $thing, $base_path, [%args] )`

The recommended, unified method for adding a swarm. It automatically detects the type of the first parameter.

```
# Add a .torrent file
$client->add("ubuntu.torrent", "./iso");

# Add a magnet link
$client->add("magnet:?xt=urn:btih:...", "./data");

# Add a v1 infohash (hex or binary)
$client->add("1bd088ee9166a062cf4af09cf99720fa6e1a3133", "./downloads");

# Add a v2 infohash (64-char hex or 32-byte binary)
$client->add("6a1259ca5ca00680...64chars...", "./downloads");
```

- **Use Case**: Easily adding any BitTorrent resource without worrying about its format.
- **Parameters**: `$thing` (Str: path, URI, or hex/binary hash), `$base_path` (Str: directory for data), `%args` (Optional Torrent parameters).
- **Returns**: A [Net::BitTorrent::Torrent](https://metacpan.org/pod/Net%3A%3ABitTorrent%3A%3ATorrent) object.

## `add_torrent( $path, $base_path, [%args] )`

Adds a torrent from a local `.torrent` file.

```perl
my $t = $client->add_torrent("linux.torrent", "/downloads");
```

- **Use Case**: Adding a swarm specifically from a metadata file.
- **Parameters**: `$path` (Str), `$base_path` (Str), `%args` (Optional parameters).
- **Returns**: A [Net::BitTorrent::Torrent](https://metacpan.org/pod/Net%3A%3ABitTorrent%3A%3ATorrent) object.

## `add_infohash( $ih, $base_path, [%args] )`

Adds a torrent by its info hash (binary or hex).

```perl
my $t = $client->add_infohash(pack('H*', '...'), './data');
```

- **Use Case**: Bootstrapping a swarm when only the hash is known (e.g., from a crawler).
- **Parameters**: `$ih` (20/32 byte Binary or 40/64 byte Hex), `$base_path` (Str).
- **Returns**: A [Net::BitTorrent::Torrent](https://metacpan.org/pod/Net%3A%3ABitTorrent%3A%3ATorrent) object.

## `add_magnet( $uri, $base_path, [%args] )`

Adds a torrent from a Magnet URI (**BEP 53**).

```perl
my $t = $client->add_magnet("magnet:?xt=urn:btmh:...", "./data");
```

- **Use Case**: Adding resources from web links.
- **Returns**: A [Net::BitTorrent::Torrent](https://metacpan.org/pod/Net%3A%3ABitTorrent%3A%3ATorrent) object.
- **Specifications**: **BEP 09** (Metadata Exchange), **BEP 53** (Magnet URIs).

## `torrents()`

Returns an arrayref of all active `Net::BitTorrent::Torrent` objects.

## `finished()`

Returns an arrayref of all managed torrents that have completed their download.

```perl
my $done = $client->finished();
say $_->name for @$done;
```

## `wait( [$condition], [$timeout] )`

Blocks (while calling `tick()`) until a condition is met or a timeout occurs.

```perl
# Wait for all torrents to finish
$client->wait();

# Wait up to 60 seconds for at least one seeder
$client->wait(sub ($c) {
    any { $_->discovered_peers > 0 } $c->torrents->@*;
}, 60);
```

- **Use Case**: Writing simple scripts that need to wait for a download to complete.
- **Parameters**: `$condition` (Optional CodeRef), `$timeout` (Optional Int: seconds).
- **Returns**: Boolean (True if condition met, False on timeout).

## `tick( [$timeout] )`

The "heartbeat" of the library. Each tick processes internal logic.

- **Use Case**: Driving the client in a manual event loop.
- **Parameters**: `$timeout` (Optional Num: duration in seconds since last call).
- **Internal Logic**: This method utilizes a "time debt" system. If a large delta is provided (e.g., 1.0s),
it will process multiple internal slices (up to 0.1s each) to ensure rate limiters and hashing queues remain
accurate. It includes a real-time cap (default 200ms) per call to maintain responsiveness for the caller's loop.
- **Intent**: This method performs discovery (DHT/LPD), updates swarm logic (choking/picking), and handles retransmissions (uTP).

## `save_state( $path )` / `load_state( $path )`

Persists session state (node ID, torrent progress) to a JSON file.

## `dht_get( $target, $callback )` / `dht_put( $value, [$callback] )`

High-level **BEP 44** API for storing and retrieving arbitrary data in the DHT.

```perl
$client->dht_put('My Shared Note', sub { say "Stored!" });
```

## `dht_scrape( $infohash, $callback )`

Performs a decentralized scrape (**BEP 33**) to find seeder/leecher counts.

## `shutdown()`

Gracefully stops all swarms and releases system resources.

# Supported Specifications

- **BEP 03**: The BitTorrent Protocol (TCP)
- **BEP 05**: Mainline DHT
- **BEP 06**: Fast Extension
- **BEP 09**: Metadata Exchange
- **BEP 10**: Extension Protocol
- **BEP 11**: Peer Exchange (PEX)
- **BEP 14**: Local Peer Discovery (LPD)
- **BEP 29**: uTP (UDP Transport)
- **BEP 42**: DHT Security Extensions
- **BEP 52**: BitTorrent v2
- **BEP 53**: Magnet URI Extension

# AUTHOR

Sanko Robinson <sanko@cpan.org>

# COPYRIGHT

Copyright (C) 2008-2026 by Sanko Robinson.

This library is free software; you can redistribute it and/or modify it under the terms of the Artistic License 2.0.
