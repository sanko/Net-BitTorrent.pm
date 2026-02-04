use v5.42;
use Test2::V1 -ipP;
no warnings;
use Net::BitTorrent::Tracker::HTTP;
subtest 'URL Building' => sub {
    my $tracker = Net::BitTorrent::Tracker::HTTP->new( url => 'http://example.com/announce' );
    my $ih      = pack( 'H*', '1234567890abcdef1234567890abcdef12345678' );
    my $id      = 'P' x 20;
    my $url     = $tracker->build_announce_url( { info_hash => $ih, peer_id => $id, port => 6881, compact => 1 } );
    like $url, qr/info_hash=%12%34%56%78%90%ab%cd%ef/,                                   'Info hash correctly escaped';
    like $url, qr/peer_id=%50%50%50%50%50%50%50%50%50%50%50%50%50%50%50%50%50%50%50%50/, 'Peer ID correctly escaped';
    like $url, qr/port=6881/,                                                            'Port present';
};
subtest 'Response Parsing' => sub {
    my $tracker = Net::BitTorrent::Tracker::HTTP->new( url => 'http://example.com/announce' );
    use Net::BitTorrent::Protocol::BEP03::Bencode qw[bencode];
    my $data = bencode( { interval => 1800, peers => pack( 'C4 n', 127, 0, 0, 1, 6881 ) } );
    my $res  = $tracker->parse_response($data);
    is $res->{interval},          1800,        'Interval parsed';
    is scalar @{ $res->{peers} }, 1,           'One peer found';
    is $res->{peers}[0]{ip},      '127.0.0.1', 'Peer IP correct';
};
done_testing;
