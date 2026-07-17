use v5.40;
use feature 'class', 'try';
no warnings 'experimental::class', 'experimental::try';
class Net::BitTorrent::Emitter v2.1.0 {
    field %on;    # event_name => [ sub { ... }, ... ]
    field $parent_emitter : writer;

    method on ( $event, $cb ) {
        push $on{$event}->@*, $cb;
        return $self;
    }

    method _emit ( $event, @args ) {
        if ( $event eq 'log' ) {
            my %extra;
            if ( @args % 2 != 0 ) {
                my $msg = shift @args;
                %extra = ( log => $msg, @args );
            }
            else {
                %extra = @args;
            }
            if ( ( $extra{level} // '' ) eq 'fatal' ) {
                die $extra{log};
            }
        }
        if ( exists $on{$event} ) {
            for my $cb ( $on{$event}->@* ) {
                try {
                    $cb->( $self, @args );
                }
                catch ($e) {
                    warn "Callback for $event failed: $e";
                }
            }
        }
        if ( defined $parent_emitter ) {
            $parent_emitter->_emit( $event, @args );
        }
    }

    method _emit_log ( $level, $message, @extra ) {
        $message =~ s/\n+$//;
        $self->_emit( log => $message, level => $level, @extra );
    }
};
1;
