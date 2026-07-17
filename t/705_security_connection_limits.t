use v5.40;
use Test2::V1 -ipP;
use lib 'lib', '../lib';
no warnings;
use Net::BitTorrent;
use Path::Tiny;
#
subtest 'Custom global limit via constructor' => sub {
    my $client = Net::BitTorrent->new( max_peers => 250 );
    is $client->max_peers, 250, 'custom max_peers accepted';
};
#
subtest 'Custom per-torrent limit via constructor' => sub {
    require Net::BitTorrent::Torrent;
    my $client = Net::BitTorrent->new();
    my $t      = Net::BitTorrent::Torrent->new( base_path => Path::Tiny->tempdir, client => $client, infohash => 'x' x 20, max_peers => 50, );
    is $t->max_peers, 50, 'custom per-torrent max_peers accepted';
};
#
subtest 'Per-torrent limit defaults to 100' => sub {
    require Net::BitTorrent::Torrent;
    my $client = Net::BitTorrent->new();
    my $t      = Net::BitTorrent::Torrent->new( base_path => Path::Tiny->tempdir, client => $client, infohash => 'x' x 20, );
    is $t->max_peers, 100, 'per-torrent max_peers defaults to 100';
};
#
subtest '_count_active_peers returns 0 with no torrents' => sub {
    my $client = Net::BitTorrent->new();
    is $client->_count_active_peers(), 0, 'no active peers';
};
#
done_testing;
