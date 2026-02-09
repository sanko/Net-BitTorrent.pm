use v5.40;
use lib '../lib';
use Net::BitTorrent::DHT;
use Net::BitTorrent::DHT::Security;
$|++;

# Generate a valid BEP 42 Node ID
my $sec = Net::BitTorrent::DHT::Security->new();
my $id  = $sec->generate_node_id('127.0.0.1');                                                # Default for local testing
my $dht = Net::BitTorrent::DHT->new( node_id_bin => $id, port => 6881 + int( rand(100) ) );
say '[INFO] Starting DHT node on port ' . $dht->port . '...';
say '[INFO] Node ID: ' . unpack( 'H*', $id );

# This will enter a loop and show stats every 30 seconds
say '[INFO] Entering main loop...';
my $last_stat = 0;
while (1) {
    $dht->tick(1);
    if ( time - $last_stat > 30 ) {
        my $stats    = $dht->routing_table_stats();
        my $v4_count = 0;
        $v4_count += $_->{count} for $stats->{v4}->@*;
        my $v6_count = 0;
        $v6_count += $_->{count} for $stats->{v6}->@*;
        say sprintf '[STAT] %s - Nodes: %d v4, %d v6. External IP: %s', scalar(localtime), $v4_count, $v6_count, ( $dht->external_ip // 'unknown' );
        $last_stat = time;
    }
}
