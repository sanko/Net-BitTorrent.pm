#!/usr/bin/env perl
use v5.40;
use Net::BitTorrent;
use Net::BitTorrent::Types qw[:all];
use Path::Tiny;

# 1. Initialize the client
# We enable UPnP for automatic port forwarding and set preferred encryption
my $client = Net::BitTorrent->new(
    user_agent   => "Net::BitTorrent Example/2.0",
    upnp_enabled => 1,
    encryption   => ENCRYPTION_PREFERRED,
    debug        => 0                                # Set to 1 for verbose protocol logs
);

# 2. Add a resource (Magnet link, .torrent file, or infohash)
# This example uses a common Linux ISO magnet link (Debian 12)
my $magnet       = 'magnet:?xt=urn:btih:6a1259ca5ca00680da60602f748fec9595ca30a5&dn=debian-12.7.0-amd64-netinst.iso';
my $download_dir = path('./downloads');
$download_dir->mkpath;
say "Adding magnet link...";
my $torrent = $client->add( $magnet, $download_dir );

# 3. Register Event Listeners
# These callbacks react to internal state changes
# Emitted when the metadata (file list, etc) is finally fetched from the swarm
$torrent->on(
    status_update => sub ( $t, $stats ) {
        state $metadata_done = 0;
        if ( !$metadata_done && $t->is_metadata_complete ) {
            say "
Metadata received! Starting download of: " . $t->name;
            say "Files:";
            say "  - $_" for $t->files->@*;
            $metadata_done = 1;
        }
    }
);

# Emitted every time a piece is successfully verified against its hash
$torrent->on(
    piece_verified => sub ( $t, $index ) {
        printf "
Progress: [%-20s] %.2f%% (%d peers)", '#' x int( $t->progress / 5 ), $t->progress, scalar( $t->discovered_peers );
    }
);

# 4. Start the swarm
# This begins DHT discovery and tracker announces
$torrent->start();
say "Waiting for seeder discovery and download completion...";
say "(Press Ctrl+C to stop)";

# 5. The "Wait" Loop
# This blocks until the 'condition' sub returns true.
# Internally it calls $client->tick() to drive all protocol logic.
$client->wait(
    sub ($nb) {
        return $torrent->is_finished;
    }
);
say "

Download complete!";
say "File saved to: " . $torrent->files->[0];

# 6. Graceful Shutdown
$client->shutdown();
