use v5.40;
use feature 'class';
no warnings 'experimental::class';
#
class Net::BitTorrent::Protocol::BEP06 v2.0.0 : isa(Net::BitTorrent::Protocol::BEP55) {
    use constant {    # BEP 06 Message IDs
        HAVE_ALL       => 0x0E,    # 14
        HAVE_NONE      => 0x0F,    # 15
        SUGGEST_PIECE  => 0x0D,    # 13
        REJECT_REQUEST => 0x10,    # 16
        ALLOWED_FAST   => 0x11     # 17
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
        return $self->on_have_all()                              if $id == HAVE_ALL;
        return $self->on_have_none()                             if $id == HAVE_NONE;
        return $self->on_suggest( unpack( 'N', $payload ) )      if $id == SUGGEST_PIECE;
        return $self->on_reject( unpack( 'N N N', $payload ) )   if $id == REJECT_REQUEST;
        return $self->on_allowed_fast( unpack( 'N', $payload ) ) if $id == ALLOWED_FAST;
        $self->SUPER::_handle_message( $id, $payload );
    }
    method on_have_all ()  { }
    method on_have_none () { }
    method on_suggest      ($index)                    { }
    method on_reject       ( $index, $begin, $length ) { }
    method on_allowed_fast ($index)                    { }
};
#
1;
