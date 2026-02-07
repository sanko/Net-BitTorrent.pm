use v5.40;
use feature 'class';
no warnings 'experimental::class';

class Net::BitTorrent::Transport::TCP {
    use Carp qw[croak];
    use IO::Select;
    use Errno;
    field $socket : param : reader;
    field $write_buffer = '';
    field $connecting : param  = 1;
    field $filter     : reader = undef;
    field %on;
    ADJUST {
        if ( $socket && $socket->opened ) {
            $socket->blocking(0);
        }
    }

    method on ( $event, $cb ) {
        push $on{$event}->@*, $cb;
        if ( $event eq 'connected' && !$connecting ) {
            $cb->();
        }
    }

    method clear_listeners ($event) {
        if ($event) {
            $on{$event} = [];
        }
        else {
            %on = ();
        }
    }

    method set_filter ($f) {
        $filter = $f;
    }

    method send_data ($data) {
        if ( $filter && $filter->can('encrypt_data') && $filter->state eq 'PAYLOAD' ) {
            $data = $filter->encrypt_data($data);
        }

        # warn "    [DEBUG] TCP::send_data: " . length($data) . " bytes\n";
        $write_buffer .= $data;
        $self->_flush_write_buffer();
        return length $data;
    }

    method send_raw ($data) {

        # warn "    [DEBUG] TCP::send_raw: " . length($data) . " bytes\n";
        $write_buffer .= $data;
        $self->_flush_write_buffer();
        return length $data;
    }

    method _flush_write_buffer () {
        return unless length $write_buffer;
        return if $connecting;
        my $sent = $socket->syswrite($write_buffer);
        if ( defined $sent && $sent > 0 ) {
            substr( $write_buffer, 0, $sent, '' );
        }
        elsif ( !defined $sent && $! != Errno::EWOULDBLOCK && $! != Errno::EAGAIN ) {
            warn "    [DEBUG] TCP write error: $!\n";
            $self->_emit('disconnected');
        }
    }

    method tick () {
        return unless $socket && $socket->opened;
        if ($connecting) {
            my $sel = IO::Select->new($socket);
            if ( $sel->can_write(0) ) {

                # Check for actual connection success
                use Socket qw[SOL_SOCKET SO_ERROR];
                my $error = $socket->getsockopt( SOL_SOCKET, SO_ERROR );
                if ( $error == 0 ) {
                    $connecting = 0;

                    # warn "    [DEBUG] TCP connection established to " . $socket->peerhost . ":" . $socket->peerport . "\n";
                    $self->_emit('connected');
                }
                else {
                    $! = $error;
                    warn "    [DEBUG] TCP connection failed to " . $socket->peerhost . ":" . $socket->peerport . ": $!\n";
                    $self->_emit('disconnected');
                    return;
                }
            }
            else {
                return;
            }
        }

        # If we have a filter, it might have data to send (handshake)
        if ( $filter && $filter->can('write_buffer') ) {
            my $f_buf = $filter->write_buffer();
            if ( length $f_buf ) {
                $write_buffer .= $f_buf;
            }
        }
        $self->_flush_write_buffer();
        my $len = $socket->sysread( my $buffer, 65535 );
        if ( defined $len && $len > 0 ) {

            # warn "    [DEBUG] TCP::tick received $len bytes\n";
            if ($filter) {
                my $decrypted = $filter->receive_data($buffer);
                if ( $filter->state eq 'PLAINTEXT_FALLBACK' ) {
                    warn "    [DEBUG] Transport filter requested plaintext fallback\n";
                    my $leftover = $filter->buffer_in;
                    $filter = undef;
                    $self->_emit( 'filter_failed', $leftover );
                    $self->receive_data($leftover);
                    return;
                }
                elsif ( $filter->state eq 'FAILED' ) {
                    warn "    [ERROR] Transport filter handshake FAILED\n";
                    my $leftover = $filter->buffer_in;
                    $filter = undef;
                    $self->_emit( 'filter_failed', $leftover );

                    # We don't call receive_data($leftover) here because it might be MSE garbage
                    return;
                }
                if ( defined $decrypted && length $decrypted ) {
                    $self->receive_data($decrypted);
                }

                # After receiving, filter might have more to send
                my $f_buf = $filter->write_buffer();
                if ( length $f_buf ) {
                    $write_buffer .= $f_buf;
                    $self->_flush_write_buffer();
                }
            }
            else {
                $self->receive_data($buffer);
            }
        }
        elsif ( defined $len && $len == 0 ) {
            warn "    [DEBUG] TCP remote closed connection\n";
            $self->_emit('disconnected');
        }
        elsif ( !defined $len && $! != Errno::EWOULDBLOCK && $! != Errno::EAGAIN ) {
            warn "    [DEBUG] TCP read error: $!\n";
            $self->_emit('disconnected');
        }
    }

    method receive_data ($data) {
        $self->_emit( 'data', $data );
    }

    method _emit ( $event, @args ) {
        for my $cb ( $on{$event}->@* ) {
            $cb->(@args);
        }
    }

    method state () {
        return $socket && $socket->opened ? 'CONNECTED' : 'CLOSED';
    }
}
1;
