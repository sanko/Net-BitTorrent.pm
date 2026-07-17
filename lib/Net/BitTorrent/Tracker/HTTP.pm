use v5.40;
use feature 'class', 'try';
no warnings 'experimental::class', 'experimental::try';
class Net::BitTorrent::Tracker::HTTP v2.1.0 : isa(Net::BitTorrent::Tracker::Base) {
    use Net::BitTorrent::Protocol::BEP03::Bencode qw[bdecode];
    use Net::BitTorrent::Protocol::BEP23;
    use Net::BitTorrent::SSRF qw[is_safe_url];
    use HTTP::Tiny;
    use URI::Escape qw[uri_escape];

    method build_announce_url ($params) {
        my $full_url = $self->url;
        $full_url .= ( $full_url =~ /\?/ ? '&' : '?' );
        my @query;
        for my $key ( sort keys %$params ) {
            next if $key eq 'ua';
            my $val = $params->{$key} // '';
            if ( $key eq 'info_hash' || $key eq 'peer_id' ) {
                $val = join( '', map { sprintf( '%%%02x', ord($_) ) } split( '', $val ) );
            }
            else {
                $val = uri_escape($val);
            }
            push @query, "$key=$val";
        }
        return $full_url . join( '&', @query );
    }

    method build_scrape_url ($infohashes) {
        my $scrape_url = $self->url;
        if ( $scrape_url =~ /\/announce$/ ) {
            $scrape_url =~ s/\/announce$/\/scrape/;
        }
        my $full_url = $scrape_url;
        $full_url .= ( $scrape_url =~ /\?/ ? '&' : '?' );
        my @query;
        for my $ih (@$infohashes) {
            my $val = join( '', map { sprintf( '%%%02x', ord($_) ) } split( '', $ih ) );
            push @query, "info_hash=$val";
        }
        return $full_url . join( '&', @query );
    }

    method parse_response ($data) {
        my $dict = bdecode($data);
        if ( $dict->{failure_reason} ) {
            $self->_emit( log => 'Tracker failure: ' . $dict->{failure_reason}, level => 'error' );
            return $dict;
        }
        if ( defined $dict->{peers} && !ref $dict->{peers} ) {
            $dict->{peers} = Net::BitTorrent::Protocol::BEP23::unpack_peers_ipv4( $dict->{peers} );
        }
        if ( defined $dict->{peers6} && !ref $dict->{peers6} ) {
            my $p6 = Net::BitTorrent::Protocol::BEP23::unpack_peers_ipv6( $dict->{peers6} );
            $dict->{peers} = [ @{ $dict->{peers} // [] }, @$p6 ];
        }
        $dict->{peers} //= [];    # Ensure it is an array ref
        return $dict;
    }

    method perform_announce ( $params, $cb = undef ) {
        my $target = $self->build_announce_url($params);
        if ( !$self->ssrf_bypass && !is_safe_url($target) ) {
            $self->_emit( log => 'HTTP announce blocked by SSRF policy: ' . $target, level => 'warn' );
            return undef;
        }
        if ( $params->{ua} && $params->{ua}->can('get') ) {
            $params->{ua}->get(
                $target,
                sub ( $res, @ ) {
                    if ( $res->{success} ) {
                        try {
                            if ($cb) {
                                $cb->( $self->parse_response( $res->{content} ) );
                            }
                        }
                        catch ($e) {
                            $self->_emit_log( 'error', 'Error in HTTP announce callback: ' . $e );
                        }
                    }
                    else {
                        $self->_emit_log( 'error', "Async HTTP error during announce: $res->{status} $res->{reason}" );
                    }
                }
            );
            return;
        }
        my $http     = HTTP::Tiny->new();
        my $response = $http->get($target);
        if ( $response->{success} ) {
            my $parsed = $self->parse_response( $response->{content} );
            $cb->($parsed) if $cb;
            return $parsed;
        }
        else {
            $self->_emit_log( 'error', "HTTP error during announce: $response->{status} $response->{reason}" );
            return undef;
        }
    }

    method perform_scrape ( $infohashes, $cb = undef ) {
        my $target = $self->build_scrape_url($infohashes);
        if ( !$self->ssrf_bypass && !is_safe_url($target) ) {
            $self->_emit_log( 'warn', 'HTTP scrape blocked by SSRF policy: ' . $target );
            return undef;
        }

        # Note: Scrape might not have a 'ua' in $infohashes params,
        # usually client passes it or we should store it in $self.
        # For now, if we don't have it, we block.
        # Real fix: Tracker objects should have a 'ua' field.
        my $http     = HTTP::Tiny->new();
        my $response = $http->get($target);
        if ( $response->{success} ) {
            my $parsed = bdecode( $response->{content} );
            $cb->($parsed) if $cb;
            return $parsed;
        }
        else {
            $self->_emit_log( 'error', "HTTP scrape error: $response->{status} $response->{reason}" );
            return undef;
        }
    }
};
1;
