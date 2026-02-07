use v5.40;
use feature 'class';
no warnings 'experimental::class';
#
class Net::BitTorrent::Transport::TCP v2.0.0 : isa(Net::BitTorrent::Emitter) {
    use Carp qw[croak];
    use IO::Select;
    use Errno;
    #
    field $socket : param : reader;
    field $write_buffer = '';
    field $connecting : param //= 1;
    field $filter : reader : writer = undef;
    #
    ADJUST { $socket->blocking(0) if $socket && $socket->opened }

    method on ( $event, $cb ) {
        $self->SUPER::on( $event, $cb );
        if ( $event eq 'connected' && !$connecting ) {
            $cb->();
        }
    }

    method send_data ($data) {
        $data = $filter->encrypt_data($data) if $filter && $filter->can('encrypt_data') && $filter->state eq 'PAYLOAD';
        $self->_emit( debug => 'TCP::send_data: ' . length($data) . ' bytes' );
        $write_buffer .= $data;
        $self->_flush_write_buffer();
        return length $data;
    }

    method send_raw ($data) {
        $self->_emit( debug => 'TCP::send_raw: ' . length($data) . ' bytes' );
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
            $self->_emit( debug => 'TCP write error: ' . $! );
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
                    $self->_emit( debug => 'TCP connection established to ' . $socket->peerhost . ':' . $socket->peerport );
                    $self->_emit('connected');
                }
                else {
                    $! = $error;
                    $self->_emit( debug => 'TCP connection failed to ' . $socket->peerhost . ':' . $socket->peerport . ": $!" );
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
            $self->_emit( debug => "TCP::tick received $len bytes" );
            if ($filter) {
                my $decrypted = $filter->receive_data($buffer);
                if ( $filter->state eq 'PLAINTEXT_FALLBACK' ) {
                    $self->_emit( debug => 'Transport filter requested plaintext fallback' );
                    my $leftover = $filter->buffer_in;
                    $filter = undef;
                    $self->_emit( 'filter_failed', $leftover );
                    $self->receive_data($leftover);
                    return;
                }
                elsif ( $filter->state eq 'FAILED' ) {
                    $self->_emit( debug => 'Transport filter handshake FAILED' );
                    my $leftover = $filter->buffer_in;
                    $filter = undef;
                    $self->_emit( filter_failed => $leftover );

                    # We don't call receive_data($leftover) here because it might be MSE garbage
                    return;
                }
                $self->receive_data($decrypted) if defined $decrypted && length $decrypted;

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
            $self->_emit( debug => 'TCP remote closed connection' );
            $self->_emit('disconnected');
        }
        elsif ( !defined $len && $! != Errno::EWOULDBLOCK && $! != Errno::EAGAIN ) {
            $self->_emit( debug => 'TCP read error: ' . $! );
            $self->_emit('disconnected');
        }
    }
    method receive_data ($data) { $self->_emit( data => $data ) }
    method state ()             { $socket && $socket->opened ? 'CONNECTED' : 'CLOSED' }
} 1;
