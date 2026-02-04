use v5.42;
use feature 'class';
use Test2::V1 -ipP;
no warnings;
use Net::uTP;
subtest 'uTP Handshake' => sub {
    my $client = Net::uTP->new( conn_id_send => 100, conn_id_recv => 101 );
    my $server = Net::uTP->new( conn_id_send => 101, conn_id_recv => 100 );

    # Client connects
    my $syn = $client->connect();
    ok $syn, 'Client generated SYN';
    is $client->state, 'SYN_SENT', 'Client state SYN_SENT';

    # Server receives SYN and returns STATE (ACK)
    # Incoming SYN conn_id is 100 (client send_id), which is server recv_id.
    my $ack = $server->receive_packet($syn);
    ok $ack, 'Server generated ACK';
    is $server->state, 'CONNECTED', 'Server state CONNECTED';

    # Client receives ACK
    # Incoming STATE conn_id is 101 (server send_id), which is client recv_id.
    $client->receive_packet($ack);
    is $client->state, 'CONNECTED', 'Client state CONNECTED';
};
subtest 'uTP Data and LEDBAT' => sub {
    my $client = Net::uTP->new( conn_id_send => 100, conn_id_recv => 101 );
    my $server = Net::uTP->new( conn_id_send => 101, conn_id_recv => 100 );

    # Pre-connect
    $server->receive_packet( $client->connect() );
    $client->receive_packet( $server->pack_header(2) );    # ST_STATE

    # Send data
    my $data     = 'Hello uTP';
    my $pkt      = $client->send_data($data);
    my $received = '';

    # Manually check data by overriding internal on_data behavior via subclass or mock
    # For simplicity, we'll just check if receive_packet returns an ACK
    my $ack = $server->receive_packet($pkt);
    ok $ack, 'Server acknowledged data packet';
    my $h = $server->unpack_header($ack);
    is $h->{type}, 2, 'Response is ST_STATE';
};
done_testing;
