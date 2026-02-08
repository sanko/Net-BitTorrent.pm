use v5.40;
use Test2::V1 -ipP;
no warnings;
use Net::BitTorrent::Tracker::UDP;
subtest 'UDP Packet Building' => sub {
    my $tracker = Net::BitTorrent::Tracker::UDP->new( url => 'udp://127.0.0.1:6881' );
    my ( $tid, $conn_req ) = $tracker->build_connect_packet();
    is length($conn_req), 16, 'Connect packet is 16 bytes';
    my $cid      = 0x12345678;
    my $conn_res = pack( 'N N Q>', 0, $tid, $cid );

    # Refined test:
    my $ann_req = $tracker->build_announce_packet( { info_hash => 'A' x 20, peer_id => 'B' x 20, port => 6881 } );
    ok $ann_req, 'Announce packet built';
    is length($ann_req), 98, 'Announce packet is 98 bytes';
};
done_testing;
