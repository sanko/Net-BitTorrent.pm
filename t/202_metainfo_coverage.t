use v5.40;
use feature 'try';
use Test2::V1 -ipP;
no warnings;
use lib 'lib', '../lib';
use Net::BitTorrent::Torrent;
use Net::BitTorrent;
use Net::BitTorrent::Types;
use Path::Tiny;
my $torrent_dir = path('t/900_data/test_torrents');
subtest 'Standard v1 (base.torrent)' => sub {
    my $path = $torrent_dir->child('base.torrent');
    my $t    = Net::BitTorrent::Torrent->new( path => $path, base_path => '.', client => Net::BitTorrent->new() );
    ok $t->info_hash_v1,  'Has v1 info_hash';
    ok !$t->info_hash_v2, 'No v2 info_hash';
    is $t->piece_length(0), 425, 'Correct piece length for small file';
};
subtest 'v2 Only' => sub {
    my $path = $torrent_dir->child('v2_only.torrent');
    my $t    = Net::BitTorrent::Torrent->new( path => $path, base_path => '.', client => Net::BitTorrent->new() );
    ok !$t->info_hash_v1, 'No v1 info_hash';
    ok $t->info_hash_v2,  'Has v2 info_hash';
};
subtest 'Hybrid v1/v2' => sub {
    my $path = $torrent_dir->child('v2_hybrid.torrent');
    my $t    = Net::BitTorrent::Torrent->new( path => $path, base_path => '.', client => Net::BitTorrent->new() );
    ok $t->info_hash_v1, 'Has v1 info_hash';
    ok $t->info_hash_v2, 'Has v2 info_hash';
};
subtest 'Malformed: Negative File Size' => sub {
    my $path = $torrent_dir->child('negative_file_size.torrent');
    my $error;
    try { Net::BitTorrent::Torrent->new( path => $path, base_path => '.', client => Net::BitTorrent->new() ) }
    catch ($e) { $error = $e; }
    ok $error, 'Caught negative file size' or diag 'Failed to catch negative file size';
};
subtest 'Malformed: Missing Path List' => sub {
    my $path = $torrent_dir->child('missing_path_list.torrent');
    my $error;
    try { Net::BitTorrent::Torrent->new( path => $path, base_path => '.', client => Net::BitTorrent->new() ) }
    catch ($e) { $error = $e; }
    ok $error, 'Caught missing path list' or diag 'Failed to catch missing path list';
};
subtest 'Malformed: No Name' => sub {
    my $path = $torrent_dir->child('no_name.torrent');
    my $error;
    try { Net::BitTorrent::Torrent->new( path => $path, base_path => '.', client => Net::BitTorrent->new() ) }
    catch ($e) { $error = $e; }
    ok $error, 'Caught missing name' or diag 'Failed to catch missing name';
};
subtest 'Malformed: No Files' => sub {
    my $path = $torrent_dir->child('no_files.torrent');
    my $error;
    try { Net::BitTorrent::Torrent->new( path => $path, base_path => '.', client => Net::BitTorrent->new() ) }
    catch ($e) { $error = $e; }
    ok $error, 'Caught no files' or diag 'Failed to catch no files';
};
subtest 'Security: Path Traversal (absolute_filename.torrent)' => sub {
    my $path = $torrent_dir->child('absolute_filename.torrent');
    my $error;
    try { Net::BitTorrent::Torrent->new( path => $path, base_path => '.', client => Net::BitTorrent->new() ) }
    catch ($e) { $error = $e; }
    like $error, qr/Invalid path element/, 'Caught absolute path in v1 torrent';
};
subtest 'Malformed v2: Invalid File (v2_invalid_file.torrent)' => sub {
    my $path = $torrent_dir->child('v2_invalid_file.torrent');
    my $error;
    try { Net::BitTorrent::Torrent->new( path => $path, base_path => '.', client => Net::BitTorrent->new() ) }
    catch ($e) { $error = $e; }
    ok $error, 'Caught invalid file in v2 file tree';
};
done_testing;
