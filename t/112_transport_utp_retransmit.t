use v5.42;
use feature 'class';
use Test2::V1 -ipP;
no warnings;
use Net::uTP;
use Time::HiRes qw[sleep];
subtest 'uTP Retransmission' => sub {
    my $client = Net::uTP->new( conn_id_send => 100, conn_id_recv => 101 );

    # Start connection
    my $syn = $client->connect();
    is $client->state, 'SYN_SENT', 'State is SYN_SENT';

    # Wait for timeout (default 1s)
    # We simulate time passing by calling tick after a sleep
    sleep(1.1);
    my $resend = $client->tick(1.1);
    ok $resend, 'Tick returned data to resend';
    is substr( $resend, 0, 20 ), substr( $syn, 0, 20 ), 'Resent packet matches original SYN';

    # Simulate success after resend
    my $server_ack = pack( 'C C n N N N n n', ( 1 << 4 ) | 2, 0, 101, 0, 0, 1500, 500, 1 );    # ST_STATE

    # Wait, client generated a random seq_nr. Let's extract it.
    my ( $vt, $ext, $cid, $ts, $td, $wnd, $seq, $ack ) = unpack( 'C C n N N N n n', $syn );
    $server_ack = pack( 'C C n N N N n n', ( 1 << 4 ) | 2, 0, 101, 0, 0, 1500, 500, $seq );
    $client->receive_packet($server_ack);
    is $client->state, 'CONNECTED', 'State is CONNECTED after resent SYN acknowledged';
};
done_testing;
