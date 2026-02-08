use v5.40;
use feature 'class', 'try';
no warnings 'experimental::class', 'experimental::try';
class Net::BitTorrent::Tracker::UDP v2.0.0 : isa(Net::BitTorrent::Tracker::Base) {
    use Net::BitTorrent::Protocol::BEP23;
    use IO::Socket::IP;
    field $connection_id;
    field $connection_id_time = 0;
    field $transaction_id;
    field $host;
    field $port;
    field $socket;
    field %pending_transactions;    # tid => { type => ..., cb => ..., payload => ..., retries => ..., timestamp => ... }
    ADJUST {
        if ( $self->url =~ m{^udp://([^:/]+):(\d+)} ) {
            $host   = $1;
            $port   = $2;
            $socket = IO::Socket::IP->new( Proto => 'udp', Blocking => 0, ) or
                $self->_emit( log => "Could not create UDP socket: $!", level => 'fatal' );
        }
        else {
            $self->_emit( log => 'Invalid UDP tracker URL: ' . $self->url, level => 'fatal' );
        }
    }

    method _new_transaction_id () {
        return $transaction_id = int( rand( 2**31 ) );
    }

    method _is_connected () {
        return defined $connection_id && ( time() - $connection_id_time < 60 );
    }

    method tick ( $delta = 0.1 ) {
        return unless $socket;

        # Check for incoming data
        while ( $socket->recv( my $buf, 4096 ) ) {
            $self->receive_data($buf);
        }

        # Handle retransmissions
        my $now = time();
        for my $tid ( keys %pending_transactions ) {
            my $entry   = $pending_transactions{$tid};
            my $timeout = 15 * ( 2**$entry->{retries} );
            if ( $now - $entry->{timestamp} > $timeout ) {
                if ( $entry->{retries} >= 8 ) {
                    $self->_emit( log => "UDP transaction $tid timed out after 8 retries", level => 'error' );
                    delete $pending_transactions{$tid};
                    next;
                }
                $entry->{retries}++;
                $entry->{timestamp} = $now;
                $self->_send_packet( $entry->{payload} );
            }
        }
    }

    method receive_data ($data) {
        return if length($data) < 8;
        my ( $action, $tid ) = unpack( 'N N', $data );
        my $entry = delete $pending_transactions{$tid};
        if ( !$entry ) {
            $self->_emit( log => "Received UDP packet with unknown transaction ID: $tid", level => 'debug' );
            return;
        }
        try {
            if ( $action == 3 ) {    # Error
                my $msg = substr( $data, 8 );
                $self->_emit( log => "UDP Tracker error: $msg", level => 'error' );
                return;
            }
            if ( $entry->{type} eq 'connect' ) {
                my ( undef, undef, $cid ) = unpack( 'N N Q>', $data );
                $connection_id      = $cid;
                $connection_id_time = time();

                # Now that we are connected, trigger the original request
                if ( $entry->{on_connect} ) {
                    $entry->{on_connect}->();
                }
            }
            elsif ( $entry->{type} eq 'announce' ) {
                my $res = $self->parse_announce_response($data);
                $entry->{cb}->($res) if $entry->{cb};
            }
            elsif ( $entry->{type} eq 'scrape' ) {
                my $res = $self->parse_scrape_response( $data, $entry->{num_hashes} );
                $entry->{cb}->($res) if $entry->{cb};
            }
        }
        catch ($e) {
            $self->_emit( log => "Error parsing UDP tracker response: $e", level => 'error' );
        }
    }

    method _send_packet ($payload) {
        return unless $socket;
        my $dest = sockaddr_in( $port, inet_aton($host) );
        $socket->send( $payload, 0, $dest );
    }

    method build_connect_packet () {
        my $tid = $self->_new_transaction_id();
        no warnings 'portable';
        return ( $tid, pack( 'Q> N N', 0x41727101980, 0, $tid ) );
    }

    method perform_announce ( $params, $cb = undef ) {
        if ( !$self->_is_connected() ) {
            my ( $tid, $pkt ) = $self->build_connect_packet();
            $pending_transactions{$tid} = {
                type       => 'connect',
                payload    => $pkt,
                retries    => 0,
                timestamp  => time(),
                on_connect => sub { $self->perform_announce( $params, $cb ) },
            };
            $self->_send_packet($pkt);
            return;
        }
        my $pkt = $self->build_announce_packet($params);
        return unless $pkt;
        my ($tid) = unpack( 'x8 N', $pkt );    # transaction_id is at offset 12 but after action(4)

        # Wait, action(4) tid(4). So offset 12 is correct for cid(8) + action(4).
        $tid = unpack( 'N', substr( $pkt, 12, 4 ) );
        $pending_transactions{$tid} = { type => 'announce', payload => $pkt, retries => 0, timestamp => time(), cb => $cb, };
        $self->_send_packet($pkt);
    }

    method perform_scrape ( $info_hashes, $cb = undef ) {
        if ( !$self->_is_connected() ) {
            my ( $tid, $pkt ) = $self->build_connect_packet();
            $pending_transactions{$tid} = {
                type       => 'connect',
                payload    => $pkt,
                retries    => 0,
                timestamp  => time(),
                on_connect => sub { $self->perform_scrape( $info_hashes, $cb ) },
            };
            $self->_send_packet($pkt);
            return;
        }
        my $pkt = $self->build_scrape_packet($info_hashes);
        my $tid = unpack( 'N', substr( $pkt, 12, 4 ) );
        $pending_transactions{$tid}
            = { type => 'scrape', payload => $pkt, retries => 0, timestamp => time(), cb => $cb, num_hashes => scalar @$info_hashes, };
        $self->_send_packet($pkt);
    }

    method build_announce_packet ($params) {
        $self->_new_transaction_id();
        my %event_map = ( none => 0, completed => 1, started => 2, stopped => 3, );
        my $event     = $event_map{ $params->{event} // 'none' } // 0;
        my $ih        = $params->{info_hash};
        my $ih_len    = length($ih);

        # Mandatory key for tracker identification
        my $key = $params->{key} // int( rand( 2**31 ) );

        # BEP 52: Support 32-byte info_hashes
        # For UDP trackers, we use the v1 info_hash if available,
        # or truncate/hash the v2 one as per common practice if 32 bytes provided.
        # REAL BEP 52 UDP trackers expect a modified layout, but standard ones
        # usually get the 20-byte 'info_hash' (v1 or truncated).
        my $ih_20 = length($ih) == 32 ? sha1($ih) : $ih;
        return pack(
            'Q> N N a20 a20 Q> Q> Q> N N N l> n', $connection_id, 1, $transaction_id, $ih_20, $params->{peer_id}, $params->{downloaded} // 0,
            $params->{left} // 0, $params->{uploaded} // 0, $event, 0,    # ip
            $key, $params->{num_want} // -1, $params->{port}
        );
    }

    method parse_announce_response ($data) {
        my ( $action, $tid, $interval, $leechers, $seeders ) = unpack( 'N N N N N', $data );
        my $peers_raw = substr( $data, 20 );
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

        # Truncate v2 hashes to 20 bytes for scrape as well
        my $ih_data = join( '', map { length($_) == 32 ? sha1($_) : $_ } @$info_hashes );
        return pack( 'Q> N N a*', $connection_id, 2, $transaction_id, $ih_data );
    }

    method parse_scrape_response ( $data, $num_hashes ) {
        my ( $action, $tid ) = unpack( 'N N', $data );
        my $results = { files => [] };
        for ( my $i = 0; $i < $num_hashes; $i++ ) {
            my ( $seeders, $completed, $leechers ) = unpack( 'N N N', substr( $data, 8 + ( $i * 12 ), 12 ) );
            push @{ $results->{files} }, { seeders => $seeders, completed => $completed, leechers => $leechers };
        }
        return $results;
    }
} 1;
