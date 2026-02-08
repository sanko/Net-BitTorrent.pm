use v5.42;
use Test2::V1 -ipP;
use Net::uTP;
use lib 'lib';
#
subtest 'SACK Generation' => sub {
    my $utp = Net::uTP->new( conn_id_send => 100, conn_id_recv => 101 );

    # Received packets in order up to 10
    $utp->set_ack_nr(10);

    # Received out-of-order packets 12 and 13
    $utp->set_in_buffer_val( 12, 'data12' );
    $utp->set_in_buffer_val( 13, 'data13' );

    # Pack header for an ACK (ST_STATE)
    my $pkt = $utp->pack_header(2);    # ST_STATE

    # Header is 20 bytes. Extension is at offset 1.
    my $ext_type = ord( substr( $pkt, 1, 1 ) );
    is $ext_type, 1, 'Extension type is 1 (SACK)';

    # Extension block follows header
    my $ext_block = substr( $pkt, 20 );
    is length($ext_block), 6, 'SACK block length is 6';
    my ( $next_ext, $len, $mask ) = unpack( 'C C V', $ext_block );
    is $next_ext, 0, 'No next extension';
    is $len,      4, 'Extension length is 4 bytes';
    is $mask,     3, 'SACK mask is correct (bits for 12 and 13 set)';
};
subtest 'SACK Parsing' => sub {
    my $utp = Net::uTP->new( conn_id_send => 100, conn_id_recv => 101 );

    # We sent packets 50, 51, 52, 53
    $utp->set_out_buffer_val( 50, { data => 'p50', ts => time() } );
    $utp->set_out_buffer_val( 51, { data => 'p51', ts => time() } );
    $utp->set_out_buffer_val( 52, { data => 'p52', ts => time() } );
    $utp->set_out_buffer_val( 53, { data => 'p53', ts => time() } );

    # Receive ACK for 50, with SACK for 52 and 53 (missing 51)
    my $header = pack(
        'C C n N N N n n', ( 1 << 4 ) | 2,    # v1, ST_STATE
        1,                                    # Extension = SACK
        101,                                  # conn_id
        0, 0, 0,                              # metrics
        0,                                    # seq_nr
        50                                    # ack_nr
    );
    my $sack_ext = pack( 'C C V', 0, 4, 3 );
    $utp->receive_packet( $header . $sack_ext );
    my %out = $utp->out_buffer;
    ok !exists $out{50}, 'Packet 50 acknowledged';
    ok exists $out{51},  'Packet 51 still in buffer (not SACKed)';
    ok !exists $out{52}, 'Packet 52 acknowledged via SACK';
    ok !exists $out{53}, 'Packet 53 acknowledged via SACK';
};
subtest 'Out-of-order Reassembly' => sub {
    my $utp = Net::uTP->new( conn_id_send => 100, conn_id_recv => 101 );
    $utp->set_ack_nr(10);
    my @received;
    $utp->on( 'data', sub { push @received, shift } );

    # Receive 12
    my $p12 = pack( 'C C n N N N n n', ( 1 << 4 ) | 0, 0, 101, 0, 0, 0, 12, 0 ) . 'data12';
    $utp->receive_packet($p12);
    is scalar @received, 0, 'Data 12 buffered (out of order)';

    # Receive 11
    my $p11 = pack( 'C C n N N N n n', ( 1 << 4 ) | 0, 0, 101, 0, 0, 0, 11, 0 ) . 'data11';
    $utp->receive_packet($p11);
    is scalar @received, 2,        'Both packets delivered after p11 arrived';
    is $received[0],     'data11', 'Data 11 first';
    is $received[1],     'data12', 'Data 12 second';
    is $utp->ack_nr,     12,       'ack_nr updated to 12';
};
#
done_testing;
