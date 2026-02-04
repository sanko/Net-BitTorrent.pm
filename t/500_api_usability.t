use v5.40;
use Test::More;
use lib 'lib';
use Net::BitTorrent;
use Path::Tiny;
my $client = Net::BitTorrent->new( port => 0 );    # Random port

# Test unified add
ok( $client->can('add'), 'Client has add() method' );

# Mock a torrent file
my $temp         = Path::Tiny->tempdir;
my $torrent_file = $temp->child("test.torrent");
$torrent_file->spew("dummy data");

# We can't easily test add_torrent without a real bencoded file and
# Net::BitTorrent::Torrent doing complex things in BUILD,
# but we can check the logic flow.
# Test event system
my $added = 0;
$client->on( torrent_added => sub { $added++ } );

# Try adding a magnet link (won't actually connect to anything)
my $magnet = "magnet:?xt=urn:btih:1bd088ee9166a062cf4af09cf99720fa6e1a3133&dn=debian-12.7.0-amd64-netinst.iso";
my $t      = $client->add( $magnet, $temp->stringify );
is( $added, 1, 'torrent_added event emitted' );
isa_ok( $t, 'Net::BitTorrent::Torrent' );

# Test Torrent helper methods
ok( $t->can('progress'),    'Torrent has progress() method' );
ok( $t->can('is_finished'), 'Torrent has is_finished() method' );

# Magnet link with no metadata yet
warn "DEBUG: State is " . $t->state . "\n";
is( $t->progress, 0, 'Progress is 0 for magnet without metadata' );
ok( !$t->is_finished,          'Not finished yet' );
ok( !$t->is_metadata_complete, 'Metadata not complete yet' );

# Test client wait with timeout
my $start = time();
my $res   = $client->wait( sub {0}, 1 );    # Wait for something that never happens, 1s timeout
my $end   = time();
ok( !$res, 'wait() timed out as expected' );
cmp_ok( $end - $start, '>=', 1, 'wait() actually waited' );
done_testing();
