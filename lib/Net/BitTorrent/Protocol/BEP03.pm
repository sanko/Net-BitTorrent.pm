use v5.40;
use feature 'class';
no warnings 'experimental::class';
#
class Net::BitTorrent::Protocol::BEP03 v2.0.0 : isa(Net::BitTorrent::Emitter) {
    use constant { HANDSHAKE => 0, OPEN => 1, CLOSED => 2 };
    #
    field $info_hash : param = undef;
    field $peer_id   : param : reader;
    field $reserved  : param : reader : writer //= "\0" x 8;
    field $debug     : param : reader = 0;
    field $state     : reader = HANDSHAKE;
    field $buffer_in            = '';
    field $buffer_out           = '';
    field $handshake_sent       = 0;
    field $detected_ih : reader = undef;
    field $processing           = 0;

    # Message IDs
    use constant {
        CHOKE          => 0,
        UNCHOKE        => 1,
        INTERESTED     => 2,
        NOT_INTERESTED => 3,
        HAVE           => 4,
        BITFIELD       => 5,
        REQUEST        => 6,
        PIECE          => 7,
        CANCEL         => 8,

        # BEP 52
        HASH_REQUEST => 21,
        HASHES       => 22,
        HASH_REJECT  => 23
    };

    method set_reserved_bit ( $byte, $mask ) {
        no warnings 'numeric';
        my $val = ord( substr( $reserved, $byte, 1 ) );
        $val |= $mask;
        $reserved = substr( $reserved, 0, $byte ) . chr($val) . substr( $reserved, $byte + 1 );
    }

    method send_handshake () {
        return $self->_emit( debug => 'info_hash required to send handshake' ) unless defined $info_hash;
        my $ih_len = CORE::length($info_hash);
        return $self - _emit( debug => 'Info hash must be 20 or 32 bytes' ) if $ih_len != 20 && $ih_len != 32;
        $self->_emit( debug => 'Sending handshake (' . unpack( 'H*', $info_hash ) . ')' );
        my $raw = pack( 'C A19 a8', 19, 'BitTorrent protocol', $reserved ) . $info_hash . $peer_id;
        $self->_emit( debug => 'Handshake hex: ' . unpack( 'H*', $raw ) );
        $buffer_out .= $raw;
        $handshake_sent = 1;
    }

    method write_buffer () {
        my $tmp = $buffer_out;
        $buffer_out = '';
        $tmp;
    }

    method receive_data ($data) {
        $buffer_in .= $data;
        return if $processing;
        $processing = 1;
        $self->_process_buffer();
        $processing = 0;
    }

    method _process_buffer () {
        if ( $state != OPEN ) {
            $self->_process_messages();
            return;
        }
        my $old_state;
        while ( $state != CLOSED && ( !$old_state || $old_state ne $state ) ) {
            $old_state = $state;
            if ( $state == HANDSHAKE ) {
                $self->_process_handshake();
            }
            if ( $state == OPEN ) {
                $self->_process_messages();
            }
        }
    }

    method _process_handshake () {
        return if length($buffer_in) < 1;
        my $pstrlen = ord( substr( $buffer_in, 0, 1 ) );
        if ( $pstrlen != 19 ) {
            $state = CLOSED;
            $self->_emit(
                debug => 'Invalid protocol string (expected 19, got ' . $pstrlen . ') hex: ' . unpack( 'H*', substr( $buffer_in, 0, 20 ) ) );
        }
        return if length($buffer_in) < 1 + $pstrlen + 8 + 20 + 20;    # Min v1 handshake (68 bytes)
        my $pstr = substr( $buffer_in, 1, $pstrlen );
        if ( $pstr ne 'BitTorrent protocol' ) {
            $state = CLOSED;
            $self->_emit( debug => 'Invalid protocol string: ' . $pstr );
        }

        # We have at least 68 bytes.
        my $ih_len;
        if ( defined $info_hash ) {
            $ih_len = length($info_hash);
        }
        else {
            # If we have exactly 80 bytes, or more than 80, it MIGHT be a v2 handshake.
            # But it could also be a v1 handshake (68) followed by a small message.
            # A v2 handshake MUST be exactly 80 bytes if nothing else follows it.
            # For now, let's look at the actual length of the buffer.
            # If it's 68-79, it must be v1.
            # If it's exactly 80, we assume v2 if we don't know yet?
            # Actually, most swarms are still v1.
            if ( length($buffer_in) == 80 ) {
                $ih_len = 32;
            }
            elsif ( length($buffer_in) > 80 ) {

                # Could be v2 + messages OR v1 + messages.
                # This is ambiguous without knowing which IH the peer is using.
                # Standard practice: if we didn't specify, assume v1 first.
                $ih_len = 20;
            }
            else {
                $ih_len = 20;
            }
        }
        my $handshake_len = 1 + $pstrlen + 8 + $ih_len + 20;
        return if length($buffer_in) < $handshake_len;
        my $remote_res = substr( $buffer_in, 1 + $pstrlen,               8 );
        my $remote_ih  = substr( $buffer_in, 1 + $pstrlen + 8,           $ih_len );
        my $remote_id  = substr( $buffer_in, 1 + $pstrlen + 8 + $ih_len, 20 );
        if ( defined $info_hash && $remote_ih ne $info_hash ) {

            # If we were expecting v2 but got v1, it might fail here.
            $state = CLOSED;
            $self->_emit( debug => 'Info hash mismatch' );
        }
        substr( $buffer_in, 0, $handshake_len, '' );
        $state       = OPEN;
        $detected_ih = $remote_ih;
        $reserved    = $remote_res;
        $self->_emit( debug => 'Received handshake from ' . unpack( 'H*', $remote_id ) );
        $self->on_handshake( $remote_ih, $remote_id );
    }

    method _process_messages () {
        while ( length($buffer_in) >= 4 ) {
            my $msg_len = unpack 'N', substr( $buffer_in, 0, 4 );
            if ( $msg_len == 0 ) {
                substr $buffer_in, 0, 4, '';    # Keep-alive
                next;
            }
            return if length($buffer_in) < 4 + $msg_len;
            my $raw_msg = substr( $buffer_in, 0, 4 + $msg_len, '' );
            my $id      = unpack( 'C', substr( $raw_msg, 4, 1 ) );
            my $payload = substr( $raw_msg, 5 );
            $self->_emit( debug => "Received message ID $id (len " . length($payload) . ')' );
            $self->_handle_message( $id, $payload );
        }
    }
    method on_handshake    ( $ih, $id )      { }
    method _handle_message ( $id, $payload ) { }

    method send_message ( $id, $payload = '' ) {
        $self->_emit( debug => "Sending message ID $id (len " . length($payload) . ')' );
        $buffer_out .= pack( 'N C a*', 1 + length($payload), $id, $payload );
    }
    method send_keepalive ()      { $buffer_out .= pack( 'N', 0 ) }
    method send_choke ()          { $self->send_message(CHOKE) }
    method send_unchoke ()        { $self->send_message(UNCHOKE) }
    method send_interested ()     { $self->send_message(INTERESTED) }
    method send_not_interested () { $self->send_message(NOT_INTERESTED) }
    method send_have     ($index) { $self->send_message( HAVE,     pack( 'N', $index ) ) }
    method send_bitfield ($data)  { $self->send_message( BITFIELD, $data ) }
} 1;
