use v5.40;
use feature 'class';
no warnings 'experimental::class';

class Net::BitTorrent::Protocol::BEP55 : isa(Net::BitTorrent::Protocol::BEP11) {
    use Net::BitTorrent::Protocol::BEP03::Bencode qw[bencode bdecode];
    use Net::BitTorrent::Protocol::BEP23;
    use Carp qw[croak];

    # BEP 55 Message IDs (internal to ut_holepunch)
    use constant { HP_RENDEZVOUS => 0, HP_CONNECT => 1, HP_ERROR => 2, };

    method send_hp_rendezvous ($target_id) {
        return unless exists $self->remote_extensions->{ut_holepunch};
        my $payload = bencode( { id => $target_id, } );
        $self->send_ext_message( 'ut_holepunch', pack( 'C a*', HP_RENDEZVOUS, $payload ) );
    }

    method send_hp_connect ( $ip, $port ) {
        return unless exists $self->remote_extensions->{ut_holepunch};
        my $payload = bencode( { addr => $ip, port => $port, } );
        $self->send_ext_message( 'ut_holepunch', pack( 'C a*', HP_CONNECT, $payload ) );
    }

    method send_hp_error ($err_code) {
        return unless exists $self->remote_extensions->{ut_holepunch};
        my $payload = bencode( { e => $err_code, } );
        $self->send_ext_message( 'ut_holepunch', pack( 'C a*', HP_ERROR, $payload ) );
    }

    method on_extended_message ( $name, $payload ) {
        if ( $name eq 'ut_holepunch' ) {
            my $type = unpack( 'C', substr( $payload, 0, 1, '' ) );
            my $dict = bdecode($payload);
            if ( $type == HP_RENDEZVOUS ) {
                $self->on_hp_rendezvous( $dict->{id} );
            }
            elsif ( $type == HP_CONNECT ) {
                $self->on_hp_connect( $dict->{addr}, $dict->{port} );
            }
            elsif ( $type == HP_ERROR ) {
                $self->on_hp_error( $dict->{e} );
            }
        }
        else {
            $self->SUPER::on_extended_message( $name, $payload );
        }
    }
    method on_hp_rendezvous ($id)          { }
    method on_hp_connect    ( $ip, $port ) { }
    method on_hp_error      ($err)         { }
}
1;
__END__

=pod

=head1 NAME

Net::BitTorrent::Protocol::BEP55 - Holepunching Extension (NAT Traversal)

=head1 DESCRIPTION

This module implements the C<ut_holepunch> extension (BEP 55), allowing  peers to coordinate NAT traversal for uTP
connections.

=head1 METHODS

=head2 send_hp_rendezvous($target_id)

Requests a rendezvous with a target peer via this peer.

=head2 send_hp_connect($ip, $port)

Instructs a target peer to connect back to a source peer.

=head2 send_hp_error($err_code)

Sends an error message (e.g. peer not found).

=cut
