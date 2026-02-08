use v5.40;
use lib 'lib';
use Test::More;
use Net::BitTorrent::DHT;
use Time::HiRes qw[sleep];

# We need to access the internal field $external_ip which isn't easy in 'class'
# unless we have a writer or use a trick.
# Let's add a writer for testing or just test the rotation by calling the detected event.
my $dht        = Net::BitTorrent::DHT->new( port => 0, bep42 => 1, node_id_rotation_interval => 1 );
my $initial_id = $dht->node_id_bin;
ok( length($initial_id) == 20, "Initial node ID is 20 bytes" );

# Simulate external IP detection
$dht->_emit( 'external_ip_detected', '127.0.0.1' );
my $id_after_ip = $dht->node_id_bin;
isnt( $id_after_ip, $initial_id, "Node ID changed after external IP detected (BEP 42)" );

# Wait for rotation interval
sleep(1.1);
$dht->tick(0);
my $final_id = $dht->node_id_bin;

# Since we haven't actually updated the internal $external_ip field (it's private),
# tick()'s _rotate_node_id might not have rotated it yet if it checks the field.
# Let's check if the current DHT.pm implementation of _rotate_node_id uses $external_ip.
# If it didn't rotate, it's because $external_ip is undef.
# I'll update DHT.pm to ensure $external_ip is updated when external_ip_detected is emitted.
isnt( $final_id, $id_after_ip, "Node ID rotated automatically after interval" ) or diag("Note: this might fail if internal field wasn't set");
done_testing();
