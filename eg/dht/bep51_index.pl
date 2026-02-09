use v5.40;
use lib '../lib';
use Net::BitTorrent::DHT;
use Net::BitTorrent::DHT::Security;
use Digest::SHA qw[sha1];
$|++;

# This script demonstrates BEP 51: DHT Infohash Indexing.
# It queries a node for a sample of the info-hashes it is tracking.
my $sec = Net::BitTorrent::DHT::Security->new();
my $id  = $sec->generate_node_id('127.0.0.1');

# Setup a "Server" node that has some data
my $server = Net::BitTorrent::DHT->new( node_id_bin => $id, port => 6881, address => '127.0.0.1' );

# Populate server storage
$server->peer_storage->put( sha1("fake torrent $_"), [ { ip => '1.2.3.4', port => 1234 } ] ) for 1 .. 25;

# Setup a "Client" node to query the server
my $client = Net::BitTorrent::DHT->new( node_id_bin => $sec->generate_node_id('127.0.0.1'), port => 6882, address => '127.0.0.1' );
say '[INFO] Server on 6881, Client on 6882';
say '[DEMO] Client requesting samples from Server...';

# Send the query
$client->sample_infohashes_remote( sha1('target'), '127.0.0.1', 6881 );

# Process the exchange
# Usually you'd do this in an event loop. Here we pump both sockets.
my $sel   = IO::Select->new( $server->socket, $client->socket );
my $found = 0;
my $start = time;
while ( time - $start < 5 && !$found ) {
    if ( my @ready = $sel->can_read(0.1) ) {
        for my $fh (@ready) {
            if ( $fh == $server->socket ) {
                $server->handle_incoming();
            }
            else {
                my ( $nodes, $peers, $data ) = $client->handle_incoming();
                if ( $data && $data->{samples} ) {
                    say '[SUCCESS] Received ' . scalar( $data->{samples}->@* ) . ' info-hash samples';
                    say '  First sample: ' . unpack( 'H*', $data->{samples}[0] );
                    say '  Total tracked by server: ' . $data->{num};
                    $found = 1;
                }
            }
        }
    }
}
say $found? '[INFO] Demo complete.' : '[ERROR] Demo timed out';
