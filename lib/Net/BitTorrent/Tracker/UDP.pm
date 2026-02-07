use v5.40;
use feature 'class';
no warnings 'experimental::class';
#
class Net::BitTorrent::Tracker::UDP v2.0.0 : isa(Net::BitTorrent::Tracker::Base) {
    use Net::BitTorrent::Protocol::BEP23;
    use IO::Socket::IP;
    use IO::Select;
    #
    field $connection_id;
    field $connection_id_time = 0;
    field $transaction_id;
    field $host;
    field $port;
    #
    ADJUST {
        if ( $self->url =~ m{^udp://([^:/]+):(\d+)} ) {
            $host = $1;
            $port = $2;
        }
        else {
            $self->_emit( 'Invalid UDP tracker URL: ' . $self->url );
            $self = undef;
        }
    }
    method _new_transaction_id () { $transaction_id = int( rand( 2**31 ) ) }
    method _is_connected ()       { defined $connection_id && ( time() - $connection_id_time < 60 ) }

    method build_connect_packet () {
        $self->_new_transaction_id();
        no warnings 'portable';
        pack 'Q> N N', 0x41727101980, 0, $transaction_id;
    }

    method parse_connect_response ($data) {
        my ( $action, $tid, $cid ) = unpack( 'N N Q>', $data );
        if ( $action == 3 ) {
            $self->_emit( debug => 'UDP Tracker error: ' . substr( $data, 8 ) );
        }
        if ( $tid != $transaction_id ) {
            $self->_emit( debug => 'Transaction ID mismatch' );
        }
        else {
            $connection_id      = $cid;
            $connection_id_time = time();
            return $cid;
        }
    }

    method build_announce_packet ($params) {
        $self->_new_transaction_id();
        my %event_map = ( none => 0, completed => 1, started => 2, stopped => 3, );
        my $event     = $event_map{ $params->{event} // 'none' } // 0;
        my $ih        = $params->{info_hash};
        my $ih_len    = length($ih);
        return !$self->_emit( debug => "Invalid info_hash length: $ih_len" ) if $ih_len != 20 && $ih_len != 32;

        # Mandatory key for tracker identification
        my $key = $params->{key} // int( rand( 2**31 ) );

        # BEP 52: if info_hash is 32 bytes, the packet layout shifts.
        # However, many UDP trackers still expect v1 format or use a modified layout.
        # Standard BEP 15 layout:
        # cid(8) action(4) tid(4) ih(20) pid(20) down(8) left(8) up(8) event(4) ip(4) key(4) want(4) port(2)
        # If it's v2, we usually only announce to trackers supporting it,
        # but BEP 15 itself doesn't explicitly define a v2 layout.
        # Most implementations truncate or use separate protocols.
        # For now, let's stick to the 20-byte ih format and warn if v2.
        if ( $ih_len == 32 ) {

            # UDP trackers usually don't support 32-byte IH yet in the same packet.
            # We truncate to 20 bytes if it's v2? No, that's wrong.
            # Actually, most trackers want the v1-equivalent IH if it's hybrid.
            # If it's pure v2, we might be out of luck with standard UDP trackers.
            $self->_emit( debug => 'UDP Tracker announce with 32-byte info_hash might not be supported by remote' );
        }
        pack 'Q> N N a20 a20 Q> Q> Q> N N N l> n', $connection_id, 1, $transaction_id, substr( $ih, 0, 20 ), $params->{peer_id},
            $params->{downloaded} // 0, $params->{left} // 0, $params->{uploaded} // 0, $event, 0,    # ip
            $key, $params->{num_want} // -1, $params->{port};
    }

    method parse_announce_response ($data) {
        my ( $action, $tid, $interval, $leechers, $seeders ) = unpack 'N N N N N', $data;
        if ( $action == 3 ) {
            return !$self->_emit( debug => 'UDP Tracker error: ' . substr( $data, 8 ) );
        }
        return !$self->_emit( debug => 'Transaction ID mismatch' ) if $tid != $transaction_id;
        my $peers_raw = substr( $data, 20 );

        # BEP 07: IPv6 peers are 18 bytes each. IPv4 are 6 bytes.
        # Trackers usually send one or the other based on request or availability.
        my $peers;
        if ( length($peers_raw) % 18 == 0 && length($peers_raw) % 6 != 0 ) {
            $peers = Net::BitTorrent::Protocol::BEP23::unpack_peers_ipv6($peers_raw);
        }
        else {
            $peers = Net::BitTorrent::Protocol::BEP23::unpack_peers_ipv4($peers_raw);
        }
        return { interval => $interval, leechers => $leechers, seeders => $seeders, peers => $peers, };
    }

    method build_scrape_packet ($info_hashes) {
        $self->_new_transaction_id();

        # BEP 52 note: scrape for v2 hashes also supported.
        pack 'Q> N N a*', $connection_id, 2, $transaction_id, join( '', @$info_hashes );
    }

    method parse_scrape_response ( $data, $num_hashes ) {
        my ( $action, $tid ) = unpack( 'N N', $data );
        if ( $action == 3 ) {
            return !$self->_emit( debug => 'UDP Tracker error: ' . substr( $data, 8 ) );
        }
        return !$self->_emit('Transaction ID mismatch') if $tid != $transaction_id;
        my $results = { files => [] };

        # Scrape results are 12 bytes per hash: seeders(4), completed(4), leechers(4)
        for ( my $i = 0; $i < $num_hashes; $i++ ) {
            my ( $seeders, $completed, $leechers ) = unpack( 'N N N', substr( $data, 8 + ( $i * 12 ), 12 ) );
            push @{ $results->{files} }, { seeders => $seeders, completed => $completed, leechers => $leechers };
        }
        $results;
    }

    method perform_announce ( $params, $cb = undef ) {
        my $sock = IO::Socket::IP->new( PeerAddr => $host, PeerPort => $port, Proto => 'udp' ) or
            return !$self->_emit( debug => 'Could not create UDP socket: ' . $! );
        my $sel = IO::Select->new($sock);

        # Connect (if needed)
        if ( !$self->_is_connected() ) {
            my $conn_req = $self->build_connect_packet();
            my $buf;
            my $success = 0;
            for ( my $n = 0; $n <= 8; $n++ ) {
                $sock->send($conn_req);
                my $timeout = 15 * ( 2**$n );
                if ( $sel->can_read($timeout) ) {
                    $sock->recv( $buf, 1024 );
                    eval { $self->parse_connect_response($buf) };
                    if ( !$@ ) {
                        $success = 1;
                        last;
                    }
                }
            }
            return $self->_emit( debug => 'UDP connect failed after retries' ) unless $success;
        }

        # Announce
        my $ann_req = $self->build_announce_packet($params);
        my $buf;
        my $res;
        my $success = 0;
        for ( my $n = 0; $n <= 8; $n++ ) {
            $sock->send($ann_req);
            my $timeout = 15 * ( 2**$n );
            if ( $sel->can_read($timeout) ) {
                $sock->recv( $buf, 4096 );
                eval { $res = $self->parse_announce_response($buf) };
                if ( !$@ ) {
                    $success = 1;
                    last;
                }
            }
        }
        return !$self->_emit( debug => 'UDP announce failed after retries' ) unless $success;
        $cb->($res) if $cb;
        $res;
    }

    method perform_scrape ( $info_hashes, $cb = undef ) {
        my $sock = IO::Socket::IP->new( PeerAddr => $host, PeerPort => $port, Proto => 'udp' ) or
            return !$self->_emit( debug => 'Could not create UDP socket: ' . $! );
        my $sel = IO::Select->new($sock);
        if ( !$self->_is_connected() ) {
            my $conn_req = $self->build_connect_packet();
            my $buf;
            my $success = 0;
            for ( my $n = 0; $n <= 8; $n++ ) {
                $sock->send($conn_req);
                my $timeout = 15 * ( 2**$n );
                if ( $sel->can_read($timeout) ) {
                    $sock->recv( $buf, 1024 );
                    eval { $self->parse_connect_response($buf) };
                    if ( !$@ ) {
                        $success = 1;
                        last;
                    }
                }
            }
            return !$self->_emit( debug => 'UDP connect failed after retries' ) unless $success;
        }
        my $scr_req = $self->build_scrape_packet($info_hashes);
        my $buf;
        my $res;
        my $success = 0;
        for ( my $n = 0; $n <= 8; $n++ ) {
            $sock->send($scr_req);
            my $timeout = 15 * ( 2**$n );
            if ( $sel->can_read($timeout) ) {
                $sock->recv( $buf, 4096 );
                eval { $res = $self->parse_scrape_response( $buf, scalar @$info_hashes ) };
                if ( !$@ ) {
                    $success = 1;
                    last;
                }
            }
        }
        return !$self->_emit( debug => 'UDP scrape failed after retries' ) unless $success;
        $cb->($res) if $cb;
        return $res;
    }
    }
    #
    1;
