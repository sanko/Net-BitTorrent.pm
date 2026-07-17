use v5.40;
use Test2::V1 -ipP;
use lib 'lib', '../lib';
use Net::BitTorrent::SSRF qw[is_safe_ip is_safe_host is_safe_url];
#
subtest 'Blocks loopback IPv4' => sub {
    is is_safe_ip('127.0.0.1'),       F(), '127.0.0.1 blocked';
    is is_safe_ip('127.255.255.255'), F(), '127.255.255.255 blocked';
};
#
subtest 'Blocks private 10.x' => sub {
    is is_safe_ip('10.0.0.1'),       F(), '10.0.0.1 blocked';
    is is_safe_ip('10.255.255.255'), F(), '10.255.255.255 blocked';
};
#
subtest 'Blocks private 172.16.x' => sub {
    is is_safe_ip('172.16.0.1'),     F(), '172.16.0.1 blocked';
    is is_safe_ip('172.31.255.255'), F(), '172.31.255.255 blocked';
    ok is_safe_ip('172.15.0.1'), F(), '172.15.0.1 allowed (below range)';
    ok is_safe_ip('172.32.0.1'), F(), '172.32.0.1 allowed (above range)';
};
#
subtest 'Blocks private 192.168.x' => sub {
    is is_safe_ip('192.168.0.1'),     F(), '192.168.0.1 blocked';
    is is_safe_ip('192.168.255.255'), F(), '192.168.255.255 blocked';
};
#
subtest 'Blocks link-local 169.254.x' => sub {
    is is_safe_ip('169.254.0.1'),     F(), '169.254.0.1 blocked';
    is is_safe_ip('169.254.169.254'), F(), '169.254.169.254 (cloud metadata) blocked';
    is is_safe_ip('169.254.255.255'), F(), '169.254.255.255 blocked';
};
#
subtest 'Blocks 0.0.0.0' => sub {
    is is_safe_ip('0.0.0.0'), F(), '0.0.0.0 blocked';
};
#
subtest 'Blocks multicast' => sub {
    is is_safe_ip('224.0.0.1'),       F(), '224.0.0.1 blocked';
    is is_safe_ip('239.255.255.255'), F(), '239.255.255.255 blocked';
};
#
subtest 'Blocks loopback IPv6' => sub {
    is is_safe_ip('::1'), F(), '::1 blocked';
};
#
subtest 'Blocks link-local IPv6' => sub {
    is is_safe_ip('fe80::1'), F(), 'fe80::1 blocked';
};
#
subtest 'Blocks ULA IPv6' => sub {
    is is_safe_ip('fc00::1'), F(), 'fc00::1 blocked';
    is is_safe_ip('fd00::1'), F(), 'fd00::1 blocked';
};
#
subtest 'Blocks multicast IPv6' => sub {
    is is_safe_ip('ff02::1'), F(), 'ff02::1 blocked';
};
#
subtest 'Allows public IPv4' => sub {
    ok is_safe_ip('8.8.8.8'),     T(), '8.8.8.8 allowed';
    ok is_safe_ip('1.1.1.1'),     T(), '1.1.1.1 allowed';
    ok is_safe_ip('203.0.113.1'), T(), '203.0.113.1 allowed';
};
#
subtest 'Allows public IPv6' => sub {
    ok is_safe_ip('2606:4700:4700::1111'), '2606:4700:4700::1111 allowed';
};
#
subtest 'Rejects garbage input' => sub {
    is is_safe_ip('not-an-ip'), F(), 'non-IP string rejected';
    is is_safe_ip(''),          F(), 'empty string rejected';
};
#
subtest 'Blocks dangerous URLs' => sub {
    is is_safe_url('http://127.0.0.1/secret'),                  F(), 'http://127.0.0.1 blocked';
    is is_safe_url('http://169.254.169.254/latest/meta-data/'), F(), 'cloud metadata URL blocked';
    is is_safe_url('http://10.0.0.1/admin'),                    F(), 'http://10.0.0.1 blocked';
    is is_safe_url('http://192.168.1.1/'),                      F(), 'http://192.168.1.1 blocked';
    is is_safe_url('http://[::1]/'),                            F(), 'http://[::1] blocked';
};
#
subtest 'Allows safe URLs' => sub {
    is is_safe_url('http://example.com/file.torrent'), T(), 'example.com allowed';
    is is_safe_url('https://example.com/announce'),    T(), 'HTTPS URL allowed';
};
#
subtest 'is_safe_host blocks IP addresses' => sub {
    is is_safe_host('127.0.0.1'),       F(), 'loopback blocked';
    is is_safe_host('10.0.0.1'),        F(), 'private 10.x blocked';
    is is_safe_host('192.168.1.1'),     F(), 'private 192.168.x blocked';
    is is_safe_host('169.254.169.254'), F(), 'cloud metadata blocked';
};
#
subtest 'is_safe_host allows public hostnames' => sub {
    ok is_safe_host('example.com'), F(), 'example.com allowed';
};
#
subtest 'HTTP tracker SSRF protection' => sub {
    require Net::BitTorrent::Tracker::HTTP;
    my $tracker = Net::BitTorrent::Tracker::HTTP->new( url => 'http://127.0.0.1/announce' );
    my $result = $tracker->perform_announce( { infohash => 'x' x 20, peer_id => 'x' x 20, port => 6881, downloaded => 0, uploaded => 0, left => 0 } );
    is $result, U(), 'announce to loopback blocked';
};
#
subtest 'HTTP tracker ssrf_bypass works' => sub {
    require Net::BitTorrent::Tracker::HTTP;
    my $tracker = Net::BitTorrent::Tracker::HTTP->new( url => 'http://127.0.0.1/announce', ssrf_bypass => 1 );
    my $result = $tracker->perform_announce( { infohash => 'x' x 20, peer_id => 'x' x 20, port => 6881, downloaded => 0, uploaded => 0, left => 0 } );
    is $result, U(), 'announce still fails (no server) but not blocked by SSRF';
};
#
subtest 'UDP tracker SSRF protection' => sub {
    require Net::BitTorrent::Tracker::UDP;
    my $died = 0;
    try { Net::BitTorrent::Tracker::UDP->new( url => 'udp://127.0.0.1:6881' ) }
    catch ($e) { $died = 1 };
    ok $died, 'UDP tracker to loopback blocked (fatal emit)';
};
#
subtest 'UDP tracker ssrf_bypass works' => sub {
    require Net::BitTorrent::Tracker::UDP;
    my $tracker = Net::BitTorrent::Tracker::UDP->new( url => 'udp://127.0.0.1:6881', ssrf_bypass => 1 );
    ok $tracker, 'UDP tracker created with bypass';
};
#
subtest resolve_and_pin => sub {
    subtest 'resolve_and_pin passes through safe IPs' => sub {
        my ( $ip, $port ) = Net::BitTorrent::SSRF::resolve_and_pin( '8.8.8.8', 80 );
        is $ip,   '8.8.8.8', 'safe IPv4 passed through';
        is $port, 80,        'port preserved';
    };
    is Net::BitTorrent::SSRF::resolve_and_pin( '127.0.0.1',                                  80 ), U(), 'loopback IP returns empty list';
    is Net::BitTorrent::SSRF::resolve_and_pin( '192.168.1.1',                                80 ), U(), 'RFC 1918 IP returns empty list';
    is Net::BitTorrent::SSRF::resolve_and_pin( '169.254.169.254',                            80 ), U(), 'cloud metadata IP returns empty list';
    is Net::BitTorrent::SSRF::resolve_and_pin( 'this-host-does-not-exist-12345.example.com', 80 ), U(), 'unresolvable hostname returns empty list';
};
#
done_testing;
