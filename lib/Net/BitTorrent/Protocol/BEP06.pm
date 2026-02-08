use v5.40;
use feature 'class';
no warnings 'experimental::class';
class Net::BitTorrent::Protocol::BEP06 v2.0.0 : isa(Net::BitTorrent::Protocol::BEP55) {

    # BEP 06 Message IDs
    use constant {
        HAVE_ALL       => 0x0E,    # 14
        HAVE_NONE      => 0x0F,    # 15
        SUGGEST_PIECE  => 0x0D,    # 13
        REJECT_REQUEST => 0x10,    # 16
        ALLOWED_FAST   => 0x11,    # 17
    };
    method send_have_all ()  { $self->send_message(HAVE_ALL) }
    method send_have_none () { $self->send_message(HAVE_NONE) }

    method send_suggest ($index) {
        $self->send_message( SUGGEST_PIECE, pack( 'N', $index ) );
    }

    method send_reject ( $index, $begin, $length ) {
        $self->send_message( REJECT_REQUEST, pack( 'N N N', $index, $begin, $length ) );
    }

    method send_allowed_fast ($index) {
        $self->send_message( ALLOWED_FAST, pack( 'N', $index ) );
    }

    method _handle_message ( $id, $payload ) {
        if ( $id == HAVE_ALL ) {
            $self->on_have_all();
        }
        elsif ( $id == HAVE_NONE ) {
            $self->on_have_none();
        }
        elsif ( $id == SUGGEST_PIECE ) {
            $self->on_suggest( unpack( 'N', $payload ) );
        }
        elsif ( $id == REJECT_REQUEST ) {
            $self->on_reject( unpack( 'N N N', $payload ) );
        }
        elsif ( $id == ALLOWED_FAST ) {
            $self->on_allowed_fast( unpack( 'N', $payload ) );
        }
        else {
            $self->SUPER::_handle_message( $id, $payload );
        }
    }
    method on_have_all ()  { }
    method on_have_none () { }
    method on_suggest      ($index)                    { }
    method on_reject       ( $index, $begin, $length ) { }
    method on_allowed_fast ($index)                    { }
} 1;
__END__

=pod

=head1 NAME

Net::BitTorrent::Protocol::BEP06 - Fast Extension Implementation

=head1 DESCRIPTION

This module implements the Fast Extension (BEP 06), adding messages to  improve startup time and error handling in
BitTorrent swarms.

=head1 METHODS

=head2 send_have_all()

Sends a C<HAVE_ALL> message, signaling that we have all pieces.

=head2 send_have_none()

Sends a C<HAVE_NONE> message, signaling that we have no pieces.

=head2 send_suggest($index)

Sends a C<SUGGEST_PIECE> message.

=head2 send_reject($index, $begin, $length)

Sends a C<REJECT_REQUEST> message.

=head2 send_allowed_fast($index)

Sends an C<ALLOWED_FAST> message.

=head2 on_have_all()

Callback triggered when a C<HAVE_ALL> message is received.

=head2 on_have_none()

Callback triggered when a C<HAVE_NONE> message is received.

=head2 on_suggest($index)

Callback triggered when a C<SUGGEST_PIECE> message is received.

=head2 on_reject($index, $begin, $length)

Callback triggered when a C<REJECT_REQUEST> message is received.

=head2 on_allowed_fast($index)

Callback triggered when an C<ALLOWED_FAST> message is received.

=cut
