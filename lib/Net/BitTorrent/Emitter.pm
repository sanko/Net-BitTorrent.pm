use v5.40;
use feature 'class', 'try';
no warnings 'experimental::class', 'experimental::try';
class Net::BitTorrent::Emitter v2.0.0 {
    field %on;    # event_name => [ sub { ... }, ... ]
    field $parent_emitter : writer;

    method on ( $event, $cb ) {
        push $on{$event}->@*, $cb;
        return $self;
    }

    method _emit ( $event, @args ) {
        if ( exists $on{$event} ) {
            for my $cb ( $on{$event}->@* ) {
                try {
                    $cb->( $self, @args );
                }
                catch ($e) {
                    warn "  [ERROR] Callback for $event failed: $e";
                }
            }
        }
        if ( defined $parent_emitter ) {
            $parent_emitter->_emit( $event, @args );
        }
    }
} 1;
