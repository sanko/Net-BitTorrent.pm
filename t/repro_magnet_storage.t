use v5.40;
use Test2::V1 -ipP;
use lib 'lib';
use Net::BitTorrent::Torrent;
use Path::Tiny;
use Digest::SHA                               qw[sha1];
use Net::BitTorrent::Protocol::BEP03::Bencode qw[bencode];
my $temp      = Path::Tiny->tempdir;
my $base_path = $temp->child('download');
$base_path->mkpath;

# Mock client
{

    package MockClient;
    use feature 'class';

    class MockClient {
        field $node_id = '1' x 20;
        method node_id()  {$node_id}
        method features() { { bep52 => 1 } }

        method limit_up() {
            state $l = do { use Algorithm::RateLimiter::TokenBucket; Algorithm::RateLimiter::TokenBucket->new( limit => 0 ) };
            $l;
        }

        method limit_down() {
            state $l = do { use Algorithm::RateLimiter::TokenBucket; Algorithm::RateLimiter::TokenBucket->new( limit => 0 ) };
            $l;
        }
        method dht() {undef}

        method queue_verification( $t, $idx, $data ) {
            $t->_verify_queued_piece( $idx, $data );
        }
    }
}
my $client = MockClient->new();

# 2. Simulate metadata received
my $info = {
    name           => 'test.iso',
    length         => 1024,
    'piece length' => 16384,
    pieces         => sha1( '0' x 1024 . "\0" x 15360 ),    # 1 piece
};
my $metadata = { info => $info };
my $ih       = sha1( bencode($info) );

# 1. Create a Torrent object with info_hash only (simulating magnet)
my $torrent = Net::BitTorrent::Torrent->new( info_hash_v1 => $ih, base_path => $base_path, client => $client, debug => 1 );

# Inject metadata and trigger _on_metadata_received
# We can't easily call private methods from outside in 'class', but we can simulate the event
$torrent->handle_metadata_data( undef, 0, length( bencode($info) ), bencode($info) );
ok( $torrent->storage, "Storage should be initialized after metadata" );

# 3. Test writing a piece
my $piece_data = '0' x 1024 . "\0" x 15360;
$torrent->receive_block( undef, 0, 0, $piece_data );

# Storage uses cache, so we need to tick or stop to flush
$torrent->tick(0.1);
my $iso_file = $base_path->child('test.iso');
ok( $iso_file->exists, "The .iso file should be created on disk" );
is( $iso_file->slurp_raw, substr( $piece_data, 0, 1024 ), "File content should match" );
done_testing;
