use v5.42;
use Test2::V1 -ipP;
no warnings;

# Mock Multicast socket before loading LPD
BEGIN {

    package IO::Socket::Multicast;

    sub new {
        my ( $class, %args ) = @_;
        bless { domain => $args{domain} // 2 }, $class;
    }
    sub mcast_add  {1}
    sub mcast_send {1}
    sub sockdomain { shift->{domain} }
    $INC{'IO/Socket/Multicast.pm'} = 1;
}
use Net::Multicast::PeerDiscovery;
use Socket qw[AF_INET AF_INET6 pack_sockaddr_in inet_aton pack_sockaddr_in6 inet_pton];
subtest 'LPD Announcement and Parsing (IPv4)' => sub {
    my @sent_packets;
    no warnings 'redefine';
    local *IO::Socket::Multicast::mcast_send = sub {
        my ( $self, $data, $dest ) = @_;
        push @sent_packets, { data => $data, dest => $dest };
        return 1;
    };
    my $lpd = Net::Multicast::PeerDiscovery->new( domain => AF_INET );
    ok $lpd->is_available, 'LPD is available with mock';
    my $ih = 'L' x 20;

    # Test Announce
    $lpd->announce( $ih, 6881 );
    ok grep( { $_->{data} =~ /Infohash: 4c4c4c4c/i } @sent_packets ), 'Sent LPD packet with correct hex infohash';

    # Test Packet Parsing
    my $found_peer;
    $lpd->on( 'peer_found', sub { $found_peer = shift } );
    my $sender_addr = pack_sockaddr_in( 6771, inet_aton('192.168.1.50') );
    $lpd->_handle_packet( $sent_packets[0]->{data}, $sender_addr );
    ok $found_peer, 'Peer found event triggered';
    is $found_peer->{ip},   '192.168.1.50', 'Correct sender IP';
    is $found_peer->{port}, 6881,           'Correct peer port';
};
subtest 'LPD IPv6 Link-Local Parsing' => sub {
    my $lpd = Net::Multicast::PeerDiscovery->new( domain => AF_INET6 );
    my $found_peer;
    $lpd->on( 'peer_found', sub { $found_peer = shift } );
    my $ih     = 'L' x 20;
    my $ih_hex = unpack( 'H*', $ih );
    my $msg    = "BT-SEARCH * HTTP/1.1\r\nPort: 6881\r\nInfohash: $ih_hex\r\n\r\n";

    # Simulate a link-local address with scope 2
    my $ip_v6       = 'fe80::1';
    my $sender_addr = pack_sockaddr_in6( 6771, inet_pton( AF_INET6, $ip_v6 ), 2, 0 );
    $lpd->_handle_packet( $msg, $sender_addr );
    ok $found_peer, 'Peer found on IPv6';
    is $found_peer->{ip},   'fe80::1%2', 'Preserved scope ID for link-local address';
    is $found_peer->{port}, 6881,        'Correct port';
};
done_testing;
