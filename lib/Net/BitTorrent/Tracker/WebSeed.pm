use v5.40;
use feature 'class';
no warnings 'experimental::class';
#
class Net::BitTorrent::Tracker::WebSeed v2.0.0 : isa(Net::BitTorrent::Emitter) {
    use HTTP::Tiny;
    use Carp qw[croak];
    #
    field $url : param : reader;    # Base URL
    field $disabled : reader = 0;
    my $http;
    #
    method fetch_piece ($segments) {
        return undef if $disabled;
        $http //= HTTP::Tiny->new( max_redirect => 5 );
        my $full_data = '';

        # URL construction
        for my $seg (@$segments) {
            my $target_url = $self->_build_url($seg);
            my $response   = $http->get( $target_url, { headers => { Range => "bytes=$seg->{offset}-" . ( $seg->{offset} + $seg->{length} - 1 ) } } );
            if ( $response->{success} ) {
                $full_data .= $response->{content};
            }
            elsif ( $response->{status} == 410 ) {
                $disabled = 1;
                $self->_emit( debug => "WebSeed Resource 410 Gone: $target_url. Disabling webseed." );
                return undef;
            }
            else {
                $self->_emit( debug => "WebSeed fetch failed: $response->{status} $response->{reason} (URL: $target_url)" );
                return undef;
            }
        }
        $full_data;
    }

    method _build_url ($seg) {
        my $target_url = $url;
        if ( $target_url =~ m{/$} ) {
            my $rel = $seg->{rel_path} // $seg->{file}->path->basename;
            $target_url .= $rel;
        }
        $target_url;
    }

    # Backward compatibility for single-file v1
    method fetch_piece_legacy ( $index, $piece_length, $total_size ) {
        my $start = $index * $piece_length;
        my $end   = $start + $piece_length - 1;
        $end = $total_size - 1 if $end >= $total_size;
        $self->fetch_piece( [ { file => undef, offset => $start, length => ( $end - $start + 1 ), rel_path => undef } ] );
    }
};
#
1;
