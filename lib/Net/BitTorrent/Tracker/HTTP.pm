use v5.40;
use feature 'class', 'try';
no warnings 'experimental::class', 'experimental::try';
class Net::BitTorrent::Tracker::HTTP v2.0.0 : isa(Net::BitTorrent::Tracker::Base) {
    use Net::BitTorrent::Protocol::BEP03::Bencode qw[bdecode];
    use Net::BitTorrent::Protocol::BEP23;
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

    method build_scrape_url ($info_hashes) {
        my $scrape_url = $self->url;
        if ( $scrape_url =~ /\/announce$/ ) {
            $scrape_url =~ s/\/announce$/\/scrape/;
        }
        my $full_url = $scrape_url;
        $full_url .= ( $scrape_url =~ /\?/ ? '&' : '?' );
        my @query;
        for my $ih (@$info_hashes) {
            my $val = join( '', map { sprintf( '%%%02x', ord($_) ) } split( '', $ih ) );
            push @query, "info_hash=$val";
        }
        return $full_url . join( '&', @query );
    }

    method parse_response ($data) {
        my $dict = bdecode($data);
        if ( $dict->{failure_reason} ) {
            $self->_emit( log => "Tracker failure: $dict->{failure_reason}", level => 'error' );
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
                            $self->_emit( log => "Error in HTTP announce callback: $e", level => 'error' );
                        }
                    }
                    else {
                        $self->_emit( log => "Async HTTP error during announce: $res->{status} $res->{reason}\n", level => 'error' );
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
            $self->_emit( log => "HTTP error during announce: $response->{status} $response->{reason}", level => 'error' );
            return undef;
        }
    }

    method perform_scrape ( $info_hashes, $cb = undef ) {
        my $target = $self->build_scrape_url($info_hashes);

        # Note: Scrape might not have a 'ua' in $info_hashes params,
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
            $self->_emit( log => "HTTP scrape error: $response->{status} $response->{reason}", level => 'error' );
            return undef;
        }
    }
} 1;
