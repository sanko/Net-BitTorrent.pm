use v5.40;
use lib '../lib';
use Test::More;
use Net::BitTorrent::Protocol::BEP53;

# BitTorrent v1 magnet
my $uri1 = "magnet:?xt=urn:btih:1bd088ee9166a062cf4af09cf99720fa6e1a3133&dn=debian-12.7.0-amd64-netinst.iso";
my $m1   = Net::BitTorrent::Protocol::BEP53->parse($uri1);
is( unpack( 'H*', $m1->info_hash_v1 ), '1bd088ee9166a062cf4af09cf99720fa6e1a3133', 'v1 IH parsed' );
is( $m1->name,                         'debian-12.7.0-amd64-netinst.iso',          'Name parsed' );

# BitTorrent v2 magnet (multihash)
my $uri2 = "magnet:?xt=urn:btmh:12206bc800aa218f10cc8d6651604758b66ad80fb2cfa3efff66d1892a8af7ade868";
my $m2   = Net::BitTorrent::Protocol::BEP53->parse($uri2);
is( unpack( 'H*', $m2->info_hash_v2 ), '6bc800aa218f10cc8d6651604758b66ad80fb2cfa3efff66d1892a8af7ade868', 'v2 IH parsed' );

# Hybrid magnet
my $uri3
    = "magnet:?xt=urn:btih:1bd088ee9166a062cf4af09cf99720fa6e1a3133&xt=urn:btmh:12206bc800aa218f10cc8d6651604758b66ad80fb2cfa3efff66d1892a8af7ade868";
my $m3 = Net::BitTorrent::Protocol::BEP53->parse($uri3);
is( unpack( 'H*', $m3->info_hash_v1 ), '1bd088ee9166a062cf4af09cf99720fa6e1a3133',                         'Hybrid v1 parsed' );
is( unpack( 'H*', $m3->info_hash_v2 ), '6bc800aa218f10cc8d6651604758b66ad80fb2cfa3efff66d1892a8af7ade868', 'Hybrid v2 parsed' );

# Generation
my $gen = Net::BitTorrent::Protocol::BEP53->new(
    info_hash_v2 => pack( 'H*', '6bc800aa218f10cc8d6651604758b66ad80fb2cfa3efff66d1892a8af7ade868' ),
    name         => 'Test'
);
like( $gen->to_string, qr/xt=urn:btmh:12206bc800aa218f10cc8d6651604758b66ad80fb2cfa3efff66d1892a8af7ade868/, 'v2 IH generated' );
like( $gen->to_string, qr/dn=Test/,                                                                          'Name generated' );
done_testing();
