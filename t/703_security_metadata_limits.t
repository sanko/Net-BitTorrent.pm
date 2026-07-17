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
use Net::BitTorrent::Protocol::BEP03::Bencode qw[bencode bdecode];
no warnings 'recursion';
#
subtest bdecode => sub {
    subtest 'MAX_BDECODE_DEPTH constant defined' => sub {
        ok defined Net::BitTorrent::Protocol::BEP03::Bencode::MAX_BDECODE_DEPTH(), 'MAX_BDECODE_DEPTH is defined';
        ok Net::BitTorrent::Protocol::BEP03::Bencode::MAX_BDECODE_DEPTH() >= 50,   'MAX_BDECODE_DEPTH >= 50 (reasonable minimum)';
        ok Net::BitTorrent::Protocol::BEP03::Bencode::MAX_BDECODE_DEPTH() <= 500,  'MAX_BDECODE_DEPTH <= 500 (reasonable maximum)';
    };
    #
    subtest 'Shallow nesting accepted' => sub {
        my $deep   = 'l' x 5 . '4:test' . 'e' x 5;
        my $result = bdecode($deep);
        ok defined $result, '5-deep nested list decodes';
        is ref $result, 'ARRAY', 'result is an array ref';
    };
    #
    subtest 'Exactly MAX_BDECODE_DEPTH nesting accepted' => sub {
        my $max    = Net::BitTorrent::Protocol::BEP03::Bencode::MAX_BDECODE_DEPTH();
        my $deep   = 'l' x $max . '4:test' . 'e' x $max;
        my $result = bdecode($deep);
        ok defined $result, "depth=$max decodes successfully";
        is ref $result, 'ARRAY', 'result is an array ref';
    };
    #
    subtest 'MAX_BDECODE_DEPTH + 1 nesting rejected' => sub {
        my $max  = Net::BitTorrent::Protocol::BEP03::Bencode::MAX_BDECODE_DEPTH();
        my $deep = 'l' x ( $max + 1 ) . '1:x' . 'e' x ( $max + 1 );
        my $died = 0;
        my $err;
        try { bdecode($deep) }
        catch ($e) { $died = 1; $err = $e };
        ok $died, 'exceeding depth limit dies';
        like $err, qr/nesting depth limit/, 'error mentions depth limit';
    };
    #
    subtest 'Deeply nested dictionaries rejected' => sub {
        my $max  = Net::BitTorrent::Protocol::BEP03::Bencode::MAX_BDECODE_DEPTH();
        my $deep = ( 'd1:a' x ( $max + 1 ) ) . '1:v' . ( 'e' x ( $max + 1 ) );
        my $died = 0;
        try { bdecode($deep) }
        catch ($e) { $died = 1 };
        ok $died, 'deeply nested dict dies';
    };
    #
    subtest 'Mixed list/dict nesting at limit accepted' => sub {
        my $max   = Net::BitTorrent::Protocol::BEP03::Bencode::MAX_BDECODE_DEPTH();
        my $inner = '4:test';
        my $str   = $inner;
        for my $i ( 1 .. $max ) {
            $str = $i % 2 ? "l${str}" : "d1:x${str}";
        }
        my $open = '';
        for my $i ( reverse 1 .. $max ) {
            $open .= $i % 2 ? 'e' : 'e';
        }
        $str .= $open;
        my $result = bdecode($str);
        ok defined $result, "mixed nesting at depth=$max decodes";
    };
    #
    subtest 'Normal (shallow) bencode still works after changes' => sub {
        is bdecode('4:spam'), 'spam', 'simple string';
        is bdecode('i42e'),   42,     'integer';
        my $el = bdecode('le');
        is $el, array {end}, 'empty list';
        my $r1 = bdecode('l4:spame');
        is $r1, array { item 0 => 'spam'; end }, 'single item list';
        my $r2 = bdecode('d3:cow3:moo4:spam4:eggse');
        is $r2, hash { field cow => 'moo'; field spam => 'eggs'; end }, 'dictionary';
        my $r3 = bdecode('li1ei2ei3ee');
        is $r3, array { item 0 => 1; item 1 => 2; item 2 => 3; end }, 'list';
    };
    #
    subtest 'MAX_FILE_TREE_DEPTH constant defined' => sub {
        is Net::BitTorrent::Torrent::MAX_FILE_TREE_DEPTH(), D(), 'MAX_FILE_TREE_DEPTH is defined';
    };
    #
    subtest 'Shallow file tree accepted' => sub {
        my $client = Net::BitTorrent->new();
        my $info   = {
            name           => 'Tree Test',
            'piece length' => 262144,
            pieces         => "\0" x 20,
            'file tree'    => { a => { b => { c => { '' => { length => 100 } } } } },
        };
        my $info_encoded = bencode($info);
        my $ih           = Digest::SHA::sha1($info_encoded);
        my $t            = Net::BitTorrent::Torrent->new( infohash => $ih, base_path => Path::Tiny->tempdir, client => $client, debug => 0, );
        $t->handle_metadata_data( undef, 0, length($info_encoded), $info_encoded );
        ok $t->storage, D(), '3-deep file tree accepted';
    };
};
#
subtest 'MAX_METADATA_SIZE constant defined' => sub {
    is Net::BitTorrent::Torrent::MAX_METADATA_SIZE(), D(), 'MAX_METADATA_SIZE is defined';
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
