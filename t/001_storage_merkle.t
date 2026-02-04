use v5.42;
use Test2::V1 -ipP;
no warnings;
use lib 'lib', '../lib';
use Digest::Merkle::SHA256;
use Digest::SHA qw[sha256];
#
subtest Basics => sub {

    # 16KiB * 8 = 128KiB file
    my $merkle = Digest::Merkle::SHA256->new( file_size => 16384 * 8 );
    is $merkle->height,     3, 'Height for 8 blocks should be 3';
    is $merkle->node_count, 8, 'Node count for 8 blocks should be 8';
    my @leaves = map { pack( 'H*', sprintf( '%064x', $_ ) ) } ( 1, 3, 3, 7, 4, 2, 0, 6 );
    for my $i ( 0 .. $#leaves ) {
        $merkle->set_block( $i, $leaves[$i] );
    }

    # Root from eg/merkle_tree.pl example
    is unpack( 'H*', $merkle->root ), '7e286a6721a66675ea033a4dcdec5abbdc7d3c81580e2d6ded7433ed113b7737', 'Correct root hash';
};
subtest Padding => sub {

    # File with 3 blocks
    my $merkle = Digest::Merkle::SHA256->new( file_size => 16384 * 3 );
    is $merkle->height, 2, 'Height for 3 blocks should be 2 (2^2 = 4)';
    my $h1 = sha256('block1');
    my $h2 = sha256('block2');
    my $h3 = sha256('block3');
    $merkle->set_block( 0, $h1 );
    $merkle->set_block( 1, $h2 );
    $merkle->set_block( 2, $h3 );

    # block 3 is zero-padded
    my $zero          = Digest::Merkle::SHA256::_zero_hash(0);
    my $level1_left   = sha256( $h1 . $h2 );
    my $level1_right  = sha256( $h3 . $zero );
    my $expected_root = sha256( $level1_left . $level1_right );
    is $merkle->root, $expected_root, 'Root with padding matches expected';
};
subtest 'Audit Path Verification' => sub {
    my $merkle = Digest::Merkle::SHA256->new( file_size => 16384 * 8 );
    my @leaves = map { pack( 'H*', sprintf( '%064x', $_ ) ) } ( 1, 3, 3, 7, 4, 2, 0, 6 );
    for my $i ( 0 .. $#leaves ) {
        $merkle->set_block( $i, $leaves[$i] );
    }
    my $root       = $merkle->root;
    my $index      = 3;
    my $hash       = $leaves[$index];
    my $audit_path = $merkle->get_audit_path($index);
    is scalar @$audit_path, 3, 'Audit path for height 3 has 3 siblings';
    ok Digest::Merkle::SHA256->verify_hash( $index,  $hash,                   $audit_path, $root ), 'verify_hash passes with correct data';
    ok !Digest::Merkle::SHA256->verify_hash( $index, pack( 'H*', 'ff' x 32 ), $audit_path, $root ), 'verify_hash fails with incorrect hash';
};
done_testing;
