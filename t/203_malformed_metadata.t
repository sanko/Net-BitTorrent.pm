use v5.42;
use Test2::V1 -ipP;
no warnings;
use lib 'lib', '../lib';
use Net::BitTorrent;
use Path::Tiny;
my $torrent_dir = path('t/900_data/test_torrents');
subtest 'Unordered Dictionary' => sub {
    my $unordered = $torrent_dir->child('unordered.torrent');
    my $error;
    try {
        my $nb = Net::BitTorrent->new();
        $nb->add_torrent( $unordered, 'temp_data' );
    }
    catch ($e) { $error = $e; }
    like( $error, qr/malformed dictionary/, 'Strict bdecode catches unordered dictionary' );
};
subtest 'Invalid Filename (Traversal Attempt)' => sub {
    my $traversal = $torrent_dir->child('absolute_filename.torrent');
    my $error;
    try {
        my $nb = Net::BitTorrent->new();
        $nb->add_torrent( $traversal, 'temp_data' );
    }
    catch ($e) { $error = $e; }
    like( $error, qr/Invalid path element/, 'Catches absolute filename' );
};
subtest 'Missing Info' => sub {
    my $missing = $torrent_dir->child('invalid_info.torrent');
    my $error;
    try {
        my $nb = Net::BitTorrent->new();
        $nb->add_torrent( $missing, 'temp_data' );
    }
    catch ($e) { $error = $e; }
    like( $error, qr/Missing info dictionary/, 'Catches missing info' );
};
subtest 'Negative Piece Length' => sub {
    my $neg = $torrent_dir->child('negative_piece_len.torrent');
    my $error;
    try {
        my $nb = Net::BitTorrent->new();
        $nb->add_torrent( $neg, 'temp_data' );
    }
    catch ($e) { $error = $e; }
    like( $error, qr/Invalid piece length/, 'Catches negative piece length' );
};
done_testing;
