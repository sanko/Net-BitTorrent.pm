use v5.40;
use feature 'class', 'try';
use Test2::V1 -ipP;
no warnings;
#
use lib 'lib', '../lib';
use Digest::SHA qw[sha1];
use Path::Tiny;
use Net::BitTorrent;
use Net::BitTorrent::Torrent;
use Net::BitTorrent::Protocol::BEP03::Bencode qw[bencode];
#
subtest 'MAX_METADATA_SIZE constant defined' => sub {
    ok defined Net::BitTorrent::Torrent::MAX_METADATA_SIZE(),              'MAX_METADATA_SIZE is defined';
    ok Net::BitTorrent::Torrent::MAX_METADATA_SIZE() > 0,                  'MAX_METADATA_SIZE is positive';
    ok Net::BitTorrent::Torrent::MAX_METADATA_SIZE() <= 100 * 1024 * 1024, 'MAX_METADATA_SIZE <= 100 MiB';
};
#
my $client = Net::BitTorrent->new();
subtest 'metadata at MAX_METADATA_SIZE accepted' => sub {
    my $info         = { name => 'At Limit', 'piece length' => 262144, pieces => "\0" x 20, length => 1024 };
    my $info_encoded = bencode($info);
    my $ih           = sha1($info_encoded);
    my $t            = Net::BitTorrent::Torrent->new( infohash => $ih, base_path => Path::Tiny->tempdir, client => $client, debug => 0 );
    $t->handle_metadata_data( undef, 0, length($info_encoded), $info_encoded );
    ok defined $t->storage, 'metadata at MAX_METADATA_SIZE accepted';
};
#
subtest 'metadata exceeding MAX_METADATA_SIZE rejected' => sub {
    my $max  = Net::BitTorrent::Torrent::MAX_METADATA_SIZE();
    my $t    = Net::BitTorrent::Torrent->new( infohash => 'D' x 20, base_path => Path::Tiny->tempdir, client => $client, debug => 0 );
    my $died = 0;
    try { $t->handle_metadata_data( undef, 0, $max + 1, 'x' x 16384 ) }
    catch ($e) { $died = 1 };
    ok $died, 'oversized metadata triggers fatal die';
    is $t->metadata_size, 0, 'metadata_size stays 0 after rejection';
    ok !defined $t->storage, 'no storage created from oversized metadata';
};
#
done_testing;
