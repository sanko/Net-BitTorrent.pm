use v5.42;
use Test2::V1 -ipP;
no warnings 'experimental::class';
use lib '../lib';
use Net::BitTorrent::Tracker::HTTP;
use Net::BitTorrent::Protocol::BEP03::Bencode qw[bencode];
#
BEGIN {
    try {
        require IO::Async::Loop;
    }
    catch ($e) {
        plan skip_all => 'IO::Async::Loop required for this test';
    }
}
use IO::Async::Loop;
#
# Mock User Agent that behaves like what perform_announce expects
# $params->{ua}->get($target, sub ($res) { ... })
package Mock::Async::UA {
    use v5.42;
    use feature 'class';
    no warnings 'experimental::class';

    class Mock::Async::UA {
        field $loop             : param;
        field $response_content : param;

        method get ( $url, $cb ) {

            # Simulate async response via the loop
            $loop->watch_idle(
                when => 'later',
                code => sub {
                    $cb->( { success => 1, content => $response_content, status => 200 } );
                }
            );
        }
    }
}
#
my $loop           = IO::Async::Loop->new;
my $tracker        = Net::BitTorrent::Tracker::HTTP->new( url => 'http://example.com/announce' );
my $expected_peers = pack( 'C4 n', 127, 0, 0, 1, 6881 );
my $response_data  = bencode( { interval => 1800, peers => $expected_peers } );
my $ua             = Mock::Async::UA->new( loop => $loop, response_content => $response_data );
my $ih             = pack( 'H*', '1234567890abcdef1234567890abcdef12345678' );
my $id             = 'P' x 20;
my $called         = 0;
my $result_peers;
$tracker->perform_announce(
    { info_hash => $ih, peer_id => $id, port => 6881, ua => $ua, },
    sub ($res) {
        $called++;
        $result_peers = $res->{peers};
        $loop->stop;
    }
);

# This should not block, but we need to run the loop to get the callback
$loop->run;
is $called,                1,           'Callback was executed';
is scalar @$result_peers,  1,           'Found one peer';
is $result_peers->[0]{ip}, '127.0.0.1', 'Correct peer IP';
#
done_testing;
