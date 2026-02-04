use v5.42;
use Test2::V1 -ipP;
no warnings;
use Net::BitTorrent;
use Net::BitTorrent::Protocol::BEP03::Bencode qw[bencode];
use Path::Tiny;
use Digest::SHA qw[sha1 sha256];
subtest 'State Persistence' => sub {
    my $temp = Path::Tiny->tempdir;

    # Create a torrent
    my $data        = 'A' x 16384;
    my $pieces_root = sha256($data);
    my $info        = {
        name           => 'persist.txt',
        'piece length' => 16384,
        pieces         => sha1($data),
        'file tree'    => { 'persist.txt' => { '' => { length => 16384, 'pieces root' => $pieces_root } } },
    };
    my $torrent_file = $temp->child('test.torrent');
    $torrent_file->spew_raw( bencode( { info => $info } ) );
    my $client = Net::BitTorrent->new();
    my $t      = $client->add_torrent( $torrent_file, $temp );

    # Mock some progress and VERIFY
    $t->bitfield->set(0);
    $t->storage->verify_block( $pieces_root, 0, $data );
    $t->storage->write_block( $pieces_root, 0, $data );

    # Dump state
    my $state = $t->dump_state();
    ok $state->{bitfield},                       'State has bitfield';
    ok $state->{storage},                        'State has storage';
    ok $state->{storage}{'persist.txt'}{merkle}, 'Storage state has merkle tree for persist.txt';

    # Create new instance and load state
    my $client2 = Net::BitTorrent->new();
    my $t2      = $client2->add_torrent( $torrent_file, $temp );
    ok !$t2->bitfield->get(0), 'New instance bitfield is empty initially';
    $t2->load_state($state);
    ok $t2->bitfield->get(0), 'Loaded instance bitfield has piece 0 set';
    is $t2->metadata->{info}{name}, 'persist.txt', 'Metadata restored correctly';

    # Verify Merkle tree restoration
    my $file2 = $t2->storage->get_file_by_root($pieces_root);
    ok $file2->merkle, 'File 2 has merkle tree';
    is $file2->merkle->root, $pieces_root, 'Merkle root is correct after load (assuming it was verified before)';
};
#
done_testing;
