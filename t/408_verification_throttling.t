use v5.42;
use Test2::V1 -ipP;
use lib '../lib';
use Net::BitTorrent;
use Path::Tiny;
use Digest::SHA                               qw[sha1];
use Net::BitTorrent::Protocol::BEP03::Bencode qw[bencode];
#
my $temp         = Path::Tiny->tempdir;
my $data         = 'V' x 16384;
my $torrent_file = $temp->child('test.torrent');
$torrent_file->spew_raw( bencode( { info => { name => 'test', 'piece length' => 16384, pieces => sha1($data) . sha1($data) } } ) );
my $client = Net::BitTorrent->new();
my $t      = $client->add_torrent( $torrent_file, $temp );
$t->start();

# Complete piece 0 and 1
$t->receive_block( undef, 0, 0, $data );
$t->receive_block( undef, 1, 0, $data );
ok !$t->bitfield->get(0), 'Piece 0 not yet verified (throttled)';
ok !$t->bitfield->get(1), 'Piece 1 not yet verified (throttled)';

# Force hashing rate limit to be very low for testing
# 16KB per second. Our piece is 16KB.
$client->set_hashing_rate_limit(16384);

# Tick 0.5s -> should process 8KB -> nothing finished
$client->tick(0.1) for 1 .. 5;
ok !$t->bitfield->get(0), 'Piece 0 still not finished after 0.5s';

# Tick another 0.6s -> total 1.1s -> should have finished piece 0
$client->tick(0.1) for 1 .. 6;
ok $t->bitfield->get(0),  'Piece 0 verified after 1.1s';
ok !$t->bitfield->get(1), 'Piece 1 still pending';

# Tick another 1.0s -> should finish piece 1
$client->tick(0.1) for 1 .. 10;
ok $t->bitfield->get(1), 'Piece 1 verified after 2.1s';
#
done_testing;
