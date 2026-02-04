use v5.42;
use Test2::V1 -ipP;
no warnings;
use Net::BitTorrent::Tracker::UDP;
subtest 'UDP Packet Building' => sub {
    my $tracker  = Net::BitTorrent::Tracker::UDP->new( url => 'udp://tracker.example.com:80' );
    my $conn_req = $tracker->build_connect_packet();
    is length($conn_req), 16, 'Connect packet is 16 bytes';
    my $cid      = 0x12345678;
    my $tid      = unpack( 'x12 N', $conn_req );
    my $conn_res = pack( 'N N Q>', 0, $tid, $cid );
    is $tracker->parse_connect_response($conn_res), $cid, 'Correctly parsed connect response';
    my $ih      = 'A' x 20;
    my $id      = 'B' x 20;
    my $ann_req = $tracker->build_announce_packet( { info_hash => $ih, peer_id => $id, port => 6881 } );
    is length($ann_req), 98, 'Announce packet is 98 bytes';
};
done_testing;
